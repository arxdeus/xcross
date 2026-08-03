import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:test/test.dart';
import 'package:apple_developer_kit/src/signing/macho_signer.dart';
import 'package:apple_developer_kit/src/signing/signing_asset.dart';
import 'package:apple_developer_kit/src/errors.dart';

void main() {
  final signingTime = DateTime.utc(2030, 2, 3, 4, 5, 6);
  late Directory temporaryDirectory;
  late SigningAsset asset;
  late MachOSigner signer;

  setUpAll(() async {
    temporaryDirectory = Directory.systemTemp.createTempSync(
      'xcross_macho_signer-',
    );
    asset = await _signingAsset(temporaryDirectory);
    signer = MachOSigner(asset);
  });

  tearDownAll(() {
    temporaryDirectory.deleteSync(recursive: true);
  });

  test('adds LC_CODE_SIGNATURE and builds SHA-256 signing slots', () {
    final original = _macho();
    final info = Uint8List.fromList(utf8.encode('Info.plist'));
    final resources = Uint8List.fromList(utf8.encode('CodeResources'));
    final signed = signer.signBytes(
      path: 'Runner',
      bytes: original,
      identifier: 'dev.xcross.Runner',
      teamIdentifier: 'TESTTEAM123',
      entitlements: _entitlements(),
      infoPlistBytes: info,
      codeResourcesBytes: resources,
      signingTime: signingTime,
    );

    expect(_u32le(signed, 16), 3);
    expect(_u32le(signed, 20), 240);
    final command = _codeSignatureCommand(signed);
    expect(command, 256);
    final codeLimit = _u32le(signed, command + 8);
    final signatureSize = _u32le(signed, command + 12);
    expect(codeLimit, 4096);
    expect(signatureSize % 16, 0);
    expect(signed.length, codeLimit + signatureSize);
    expect(_u64le(signed, 32 + 152 + 48), signed.length - 4096);
    expect(_u64le(signed, 32 + 152 + 32), _align(signed.length - 4096, 4096));

    final slots = _signatureSlots(signed, codeLimit);
    expect(slots.keys, [0, 2, 5, 7, 0x10000]);
    expect(slots, isNot(contains(0x1000)));
    final codeDirectory = slots[0]!;
    expect(_u32be(codeDirectory, 0), 0xfade0c02);
    expect(_u32be(codeDirectory, 8), 0x20400);
    expect(_u32be(codeDirectory, 32), codeLimit);
    expect(codeDirectory[36], 32);
    expect(codeDirectory[37], 2);
    expect(codeDirectory[39], 12);
    expect(_u64be(codeDirectory, 72), 4096);
    expect(_u64be(codeDirectory, 80), 0x11);
    expect(
      _cstring(codeDirectory, _u32be(codeDirectory, 20)),
      'dev.xcross.Runner',
    );
    expect(_cstring(codeDirectory, _u32be(codeDirectory, 48)), 'TESTTEAM123');

    final hashOffset = _u32be(codeDirectory, 16);
    expect(_u32be(codeDirectory, 24), 7);
    expect(
      codeDirectory.sublist(hashOffset - 32, hashOffset),
      orderedEquals(sha256.convert(info).bytes),
    );
    expect(
      codeDirectory.sublist(hashOffset - 64, hashOffset - 32),
      orderedEquals(sha256.convert(slots[2]!).bytes),
    );
    expect(
      codeDirectory.sublist(hashOffset - 96, hashOffset - 64),
      orderedEquals(sha256.convert(resources).bytes),
    );
    expect(
      codeDirectory.sublist(hashOffset - 128, hashOffset - 96),
      everyElement(0),
    );
    expect(
      codeDirectory.sublist(hashOffset - 160, hashOffset - 128),
      orderedEquals(sha256.convert(slots[5]!).bytes),
    );
    expect(
      codeDirectory.sublist(hashOffset - 192, hashOffset - 160),
      everyElement(0),
    );
    expect(
      codeDirectory.sublist(hashOffset - 224, hashOffset - 192),
      orderedEquals(sha256.convert(slots[7]!).bytes),
    );

    final pageCount = _u32be(codeDirectory, 28);
    expect(pageCount, 1);
    expect(
      codeDirectory.sublist(hashOffset, hashOffset + 32),
      orderedEquals(sha256.convert(signed.sublist(0, 4096)).bytes),
    );
    final cms = slots[0x10000]!;
    expect(_u32be(cms, 0), 0xfade0b01);
    expect(cms[8], 0x30);
    expect(_containsBytes(cms, sha256.convert(codeDirectory).bytes), isTrue);
  });

  test('hashes every 4096-byte page including a partial boundary page', () {
    final signed = signer.signBytes(
      path: 'boundary',
      bytes: _macho(signatureCapacity: 8192, linkeditPrefix: 16),
      identifier: 'dev.xcross.boundary',
      teamIdentifier: 'TESTTEAM123',
      entitlements: const {},
      signingTime: signingTime,
    );
    final command = _codeSignatureCommand(signed);
    final codeLimit = _u32le(signed, command + 8);
    expect(codeLimit, 4112);
    final codeDirectory = _signatureSlots(signed, codeLimit)[0]!;
    final hashOffset = _u32be(codeDirectory, 16);
    expect(_u32be(codeDirectory, 28), 2);
    expect(
      codeDirectory.sublist(hashOffset, hashOffset + 32),
      orderedEquals(sha256.convert(signed.sublist(0, 4096)).bytes),
    );
    expect(
      codeDirectory.sublist(hashOffset + 32, hashOffset + 64),
      orderedEquals(sha256.convert(signed.sublist(4096, 4112)).bytes),
    );
  });

  test('reuses sufficient existing signature space', () {
    final original = _macho(signatureCapacity: 8192, fileType: _mhDylib);
    final command = _codeSignatureCommand(original);
    final signed = signer.signBytes(
      path: 'reuse',
      bytes: original,
      identifier: 'dev.xcross.reuse',
      teamIdentifier: 'TESTTEAM123',
      entitlements: _entitlements(),
      signingTime: signingTime,
    );

    expect(signed.length, original.length);
    expect(_u32le(signed, command + 8), 4096);
    expect(_u32le(signed, command + 12), 8192);
    final codeDirectory = _signatureSlots(signed, 4096)[0]!;
    expect(_u64be(codeDirectory, 80), 0);
    expect(_u32be(codeDirectory, 24), 5);
    final slots = _signatureSlots(signed, 4096);
    expect(slots, isNot(contains(7)));
    expect(
      PropertyListSerialization.propertyListWithString(
        utf8.decode(slots[5]!.sublist(8)),
      ),
      isEmpty,
    );
  });

  test('grows undersized existing signature space and updates __LINKEDIT', () {
    final original = _macho(signatureCapacity: 16);
    final command = _codeSignatureCommand(original);
    final signed = signer.signBytes(
      path: 'grow',
      bytes: original,
      identifier: 'dev.xcross.grow',
      teamIdentifier: 'TESTTEAM123',
      entitlements: const {},
      signingTime: signingTime,
    );

    final size = _u32le(signed, command + 12);
    expect(size, greaterThan(16));
    expect(size % 16, 0);
    expect(signed.length, 4096 + size);
    const linkedit = 32 + 152 + 16;
    expect(_u64le(signed, linkedit + 48), size);
    expect(_u64le(signed, linkedit + 32), _align(4096 + size - 16, 4096));
  });

  test('serializes XML and DER entitlements deterministically', () {
    final first = <String, Object?>{
      'z': 'last',
      'a': <String, Object?>{
        'date': DateTime.utc(2030, 1, 2, 3, 4, 5),
        'data': Uint8List.fromList([1, 2, 3]),
        'values': <Object?>[true, -1, 128, 'text'],
      },
    };
    final second = <String, Object?>{'a': first['a'], 'z': 'last'};
    final fixture = _macho();
    Uint8List sign(Map<String, Object?> entitlements) => signer.signBytes(
      path: 'deterministic',
      bytes: fixture,
      identifier: 'dev.xcross.deterministic',
      teamIdentifier: 'TESTTEAM123',
      entitlements: entitlements,
      signingTime: signingTime,
    );

    final left = sign(first);
    final right = sign(second);
    expect(left, orderedEquals(right));
    final slots = _signatureSlots(left, 4096);
    final xml = utf8.decode(slots[5]!.sublist(8));
    expect(xml.indexOf('<key>a</key>'), lessThan(xml.indexOf('<key>z</key>')));
    final der = slots[7]!;
    expect(_u32be(der, 0), 0xfade7172);
    expect(der.sublist(8, 13), [0x70, isNot(0), 0x02, 0x01, 0x01]);
    expect(_containsBytes(der, [0x02, 0x01, 0xff]), isTrue);
    expect(_containsBytes(der, [0x02, 0x02, 0x00, 0x80]), isTrue);
    expect(_containsBytes(der, ascii.encode('20300102030405Z')), isTrue);
  });

  test('rejects unsupported entitlement values before changing input', () {
    final original = _macho();
    final before = Uint8List.fromList(original);
    expect(
      () => signer.signBytes(
        path: 'bad-entitlements',
        bytes: original,
        identifier: 'dev.xcross.bad',
        teamIdentifier: 'TESTTEAM123',
        entitlements: const {'real': 1.5},
      ),
      throwsA(
        isA<AppleError>().having(
          (error) => error.message,
          'message',
          allOf(contains('bad-entitlements'), contains('unsupported')),
        ),
      ),
    );
    expect(original, orderedEquals(before));
  });

  test(
    'preflight rejects encrypted, FAT, truncated, bounds, and slack inputs',
    () async {
      final cases = <String, Uint8List>{
        'encrypted': _macho(encrypted: true),
        'fat': Uint8List.fromList([0xca, 0xfe, 0xba, 0xbe]),
        'truncated': Uint8List.fromList([0xcf, 0xfa, 0xed, 0xfe, 0, 0]),
        'bounds': _withU32(_macho(), 20, 0xffffffff),
        'slack': _macho(commandSlack: 8),
        '32-bit': Uint8List.fromList([0xce, 0xfa, 0xed, 0xfe]),
        'big-endian': Uint8List.fromList([0xfe, 0xed, 0xfa, 0xcf]),
      };
      for (final entry in cases.entries) {
        final file = File('${temporaryDirectory.path}/${entry.key}.macho');
        file.writeAsBytesSync(entry.value);
        final before = file.readAsBytesSync();
        await expectLater(
          MachOSigner.preflight(file.path),
          throwsA(
            isA<AppleError>().having(
              (error) => error.message,
              'message',
              contains(file.path),
            ),
          ),
          reason: entry.key,
        );
        expect(
          file.readAsBytesSync(),
          orderedEquals(before),
          reason: entry.key,
        );
      }
    },
  );

  test('rejects malformed existing signature bounds', () async {
    final malformed = _macho(signatureCapacity: 16);
    final command = _codeSignatureCommand(malformed);
    _setU32le(malformed, command + 8, 4080);
    final file = File('${temporaryDirectory.path}/bad-signature.macho')
      ..writeAsBytesSync(malformed);
    await expectLater(
      MachOSigner.preflight(file.path),
      throwsA(
        isA<AppleError>().having(
          (error) => error.message,
          'message',
          contains('LC_CODE_SIGNATURE'),
        ),
      ),
    );
  });

  test('accepts linker output with an unrounded __LINKEDIT vmsize', () {
    final original = _macho(signatureCapacity: 3424, linkeditVmSize: 3424);

    expect(
      () => signer.signBytes(
        path: 'unrounded-linkedit',
        bytes: original,
        identifier: 'dev.xcross.linkedit',
        teamIdentifier: 'TESTTEAM123',
        entitlements: const {},
        signingTime: signingTime,
      ),
      returnsNormally,
    );
  });

  test(
    'signFile replaces through a valid signed file and keeps mode on POSIX',
    () async {
      final file = File('${temporaryDirectory.path}/Runner')
        ..writeAsBytesSync(_macho());
      final oldMode = file.statSync().mode & 0xfff;

      await signer.signFile(
        file.path,
        identifier: 'dev.xcross.Runner',
        teamIdentifier: 'TESTTEAM123',
        entitlements: const {},
        signingTime: signingTime,
      );

      await MachOSigner.preflight(file.path);
      expect(_u32le(file.readAsBytesSync(), 16), 3);
      if (!Platform.isWindows) expect(file.statSync().mode & 0xfff, oldMode);
    },
  );
}

Map<String, Object?> _entitlements() => <String, Object?>{
  'application-identifier': 'TESTTEAM123.dev.xcross.Runner',
  'get-task-allow': true,
};

Uint8List _macho({
  int? signatureCapacity,
  int linkeditPrefix = 0,
  int commandSlack = 16,
  bool encrypted = false,
  int fileType = _mhExecute,
  int? linkeditVmSize,
}) {
  final hasSignature = signatureCapacity != null;
  final ncmds = 2 + (hasSignature ? 1 : 0) + (encrypted ? 1 : 0);
  final sizeofcmds = 152 + 72 + (hasSignature ? 16 : 0) + (encrypted ? 24 : 0);
  final commandsEnd = 32 + sizeofcmds;
  final textOffset = commandsEnd + commandSlack;
  const linkeditOffset = 4096;
  final signatureOffset = _align(linkeditOffset + linkeditPrefix, 16);
  final fileLength = hasSignature
      ? signatureOffset + signatureCapacity
      : linkeditOffset;
  final bytes = Uint8List(fileLength);
  _setU32le(bytes, 0, 0xfeedfacf);
  _setU32le(bytes, 4, 0x0100000c);
  _setU32le(bytes, 8, 0);
  _setU32le(bytes, 12, fileType);
  _setU32le(bytes, 16, ncmds);
  _setU32le(bytes, 20, sizeofcmds);

  var command = 32;
  _setU32le(bytes, command, 0x19);
  _setU32le(bytes, command + 4, 152);
  _name(bytes, command + 8, '__TEXT');
  _setU64le(bytes, command + 32, linkeditOffset);
  _setU64le(bytes, command + 40, 0);
  _setU64le(bytes, command + 48, linkeditOffset);
  _setU32le(bytes, command + 56, 7);
  _setU32le(bytes, command + 60, 5);
  _setU32le(bytes, command + 64, 1);
  final section = command + 72;
  _name(bytes, section, '__text');
  _name(bytes, section + 16, '__TEXT');
  _setU64le(bytes, section + 32, textOffset);
  _setU64le(bytes, section + 40, 16);
  _setU32le(bytes, section + 48, textOffset);
  _setU32le(bytes, section + 52, 2);
  _setU32le(bytes, section + 64, 0x80000400);
  for (var index = 0; index < 16; index++) {
    bytes[textOffset + index] = index + 1;
  }
  command += 152;

  if (encrypted) {
    _setU32le(bytes, command, 0x2c);
    _setU32le(bytes, command + 4, 24);
    _setU32le(bytes, command + 16, 1);
    command += 24;
  }
  if (hasSignature) {
    _setU32le(bytes, command, 0x1d);
    _setU32le(bytes, command + 4, 16);
    _setU32le(bytes, command + 8, signatureOffset);
    _setU32le(bytes, command + 12, signatureCapacity);
    command += 16;
  }

  _setU32le(bytes, command, 0x19);
  _setU32le(bytes, command + 4, 72);
  _name(bytes, command + 8, '__LINKEDIT');
  final linkeditSize = fileLength - linkeditOffset;
  _setU64le(bytes, command + 24, linkeditOffset);
  _setU64le(bytes, command + 32, linkeditVmSize ?? _align(linkeditSize, 4096));
  _setU64le(bytes, command + 40, linkeditOffset);
  _setU64le(bytes, command + 48, linkeditSize);
  _setU32le(bytes, command + 56, 7);
  _setU32le(bytes, command + 60, 1);
  return bytes;
}

int _codeSignatureCommand(Uint8List bytes) {
  var command = 32;
  for (var index = 0; index < _u32le(bytes, 16); index++) {
    if (_u32le(bytes, command) == 0x1d) return command;
    command += _u32le(bytes, command + 4);
  }
  throw StateError('LC_CODE_SIGNATURE not found');
}

Map<int, Uint8List> _signatureSlots(Uint8List bytes, int offset) {
  expect(_u32be(bytes, offset), 0xfade0cc0);
  final count = _u32be(bytes, offset + 8);
  final slots = <int, Uint8List>{};
  for (var index = 0; index < count; index++) {
    final type = _u32be(bytes, offset + 12 + index * 8);
    final blobOffset = offset + _u32be(bytes, offset + 16 + index * 8);
    final length = _u32be(bytes, blobOffset + 4);
    slots[type] = Uint8List.sublistView(bytes, blobOffset, blobOffset + length);
  }
  return slots;
}

Future<SigningAsset> _signingAsset(Directory directory) {
  final keyPair = CryptoUtils.generateRSAKeyPair(keySize: 1024);
  final privateKey = keyPair.privateKey as RSAPrivateKey;
  final publicKey = keyPair.publicKey as RSAPublicKey;
  final csr = X509Utils.generateRsaCsrPem(
    {'CN': 'xcross Test Developer'},
    privateKey,
    publicKey,
  );
  final certificatePem = X509Utils.generateSelfSignedCertificate(
    privateKey,
    csr,
    7300,
    notBefore: DateTime.utc(2029),
  );
  final certificateDer = CryptoUtils.getBytesFromPEMString(certificatePem);
  final profile = <String, Object>{
    'CreationDate': DateTime.utc(2029),
    'ExpirationDate': DateTime.utc(2040),
    'TeamIdentifier': ['TESTTEAM123'],
    'ApplicationIdentifierPrefix': ['TESTTEAM123'],
    'Entitlements': <String, Object>{
      'application-identifier': 'TESTTEAM123.dev.xcross.Runner',
      'get-task-allow': true,
    },
    'DeveloperCertificates': [ByteData.sublistView(certificateDer)],
  };
  final plist = Uint8List.fromList(
    utf8.encode(PropertyListSerialization.stringWithPropertyList(profile)),
  );
  final profileCms = _sequence([
    _oid('1.2.840.113549.1.7.2'),
    _tlv(
      0xa0,
      _sequence([
        _integer(1),
        _set([_algorithmIdentifier('2.16.840.1.101.3.4.2.1')]),
        _sequence([
          _oid('1.2.840.113549.1.7.1'),
          _tlv(0xa0, _tlv(0x04, plist)),
        ]),
        _tlv(0xa0, certificateDer),
        _set(const []),
      ]),
    ),
  ]);
  final keyPath = '${directory.path}/key.pem';
  final certificatePath = '${directory.path}/certificate.pem';
  final profilePath = '${directory.path}/profile.mobileprovision';
  File(
    keyPath,
  ).writeAsStringSync(CryptoUtils.encodeRSAPrivateKeyToPem(privateKey));
  File(certificatePath).writeAsStringSync(certificatePem);
  File(profilePath).writeAsBytesSync(profileCms);
  return SigningAsset.load(
    privateKeyPemPath: keyPath,
    certificatePemPath: certificatePath,
    provisioningProfilePath: profilePath,
    now: DateTime.utc(2030),
    trustedRootCertificates: [certificateDer],
  );
}

Uint8List _algorithmIdentifier(String oid) =>
    _sequence([_oid(oid), _tlv(0x05, const [])]);

Uint8List _sequence(Iterable<Uint8List> values) =>
    _tlv(0x30, [for (final value in values) ...value]);

Uint8List _set(Iterable<Uint8List> values) =>
    _tlv(0x31, [for (final value in values) ...value]);

Uint8List _integer(int value) => _tlv(0x02, [value]);

Uint8List _oid(String value) {
  final arcs = value.split('.').map(int.parse).toList();
  return _tlv(0x06, [
    ..._base128(arcs[0] * 40 + arcs[1]),
    for (final arc in arcs.skip(2)) ..._base128(arc),
  ]);
}

List<int> _base128(int value) {
  final result = <int>[value & 0x7f];
  var remaining = value >> 7;
  while (remaining > 0) {
    result.insert(0, (remaining & 0x7f) | 0x80);
    remaining >>= 7;
  }
  return result;
}

Uint8List _tlv(int tag, Iterable<int> value) {
  final body = value.toList();
  final length = <int>[];
  var remaining = body.length;
  do {
    length.insert(0, remaining & 0xff);
    remaining >>= 8;
  } while (remaining > 0);
  return Uint8List.fromList([
    tag,
    if (body.length < 128) body.length else 0x80 | length.length,
    if (body.length >= 128) ...length,
    ...body,
  ]);
}

Uint8List _withU32(Uint8List source, int offset, int value) {
  final copy = Uint8List.fromList(source);
  _setU32le(copy, offset, value);
  return copy;
}

bool _containsBytes(List<int> bytes, List<int> needle) {
  for (var start = 0; start <= bytes.length - needle.length; start++) {
    var matches = true;
    for (var index = 0; index < needle.length; index++) {
      if (bytes[start + index] != needle[index]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}

String _cstring(Uint8List bytes, int offset) {
  final end = bytes.indexOf(0, offset);
  return utf8.decode(bytes.sublist(offset, end));
}

void _name(Uint8List bytes, int offset, String value) {
  bytes.setRange(offset, offset + value.length, ascii.encode(value));
}

const _mhExecute = 2;
const _mhDylib = 6;

int _align(int value, int alignment) =>
    value % alignment == 0 ? value : value + alignment - value % alignment;

int _u32le(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes).getUint32(offset, Endian.little);

int _u32be(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes).getUint32(offset);

int _u64le(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes).getUint64(offset, Endian.little);

int _u64be(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes).getUint64(offset);

void _setU32le(Uint8List bytes, int offset, int value) =>
    ByteData.sublistView(bytes).setUint32(offset, value, Endian.little);

void _setU64le(Uint8List bytes, int offset, int value) =>
    ByteData.sublistView(bytes).setUint64(offset, value, Endian.little);
