import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:test/test.dart';
import 'package:xcross/src/signing/bundle_signer.dart';
import 'package:xcross/src/signing/signing_asset.dart';
import 'package:xcross/src/util/errors.dart';

void main() {
  final signingTime = DateTime.utc(2030, 2, 3, 4, 5, 6);
  late Directory temporaryDirectory;
  late SigningAsset exactAsset;
  late SigningAsset wildcardAsset;

  setUpAll(() async {
    temporaryDirectory = Directory.systemTemp.createTempSync(
      'xcross_bundle_signer-',
    );
    exactAsset = await _signingAsset(
      temporaryDirectory,
      'exact',
      'TESTTEAM123.dev.xcross.Runner',
    );
    wildcardAsset = await _signingAsset(
      temporaryDirectory,
      'wildcard',
      'TESTTEAM123.dev.xcross.*',
    );
  });

  tearDownAll(() {
    temporaryDirectory.deleteSync(recursive: true);
  });

  test(
    'signs children first and emits deterministic zsign file seals',
    () async {
      final app = _app(temporaryDirectory, 'complete', 'dev.xcross.Runner');
      final appFramework = p.join(app.path, 'Frameworks', 'App.framework');
      final flutterFramework = p.join(
        app.path,
        'Frameworks',
        'Flutter.framework',
      );
      File(p.join(app.path, 'resource.txt')).writeAsStringSync('resource');
      Directory(p.join(app.path, 'Base.lproj')).createSync();
      File(
        p.join(app.path, 'Base.lproj', 'Localizable.strings'),
      ).writeAsStringSync('optional');
      Directory(p.join(app.path, '_CodeSignature')).createSync();
      File(
        p.join(app.path, '_CodeSignature', 'stale'),
      ).writeAsStringSync('old');
      for (final framework in [appFramework, flutterFramework]) {
        Directory(p.join(framework, '_CodeSignature')).createSync();
        File(
          p.join(framework, '_CodeSignature', 'stale'),
        ).writeAsStringSync('old');
        File(
          p.join(framework, 'embedded.mobileprovision'),
        ).writeAsStringSync('nested');
      }

      final signer = BundleSigner(exactAsset);
      await signer.signApp(app.path, signingTime: signingTime);

      expect(
        File(p.join(app.path, 'embedded.mobileprovision')).readAsBytesSync(),
        orderedEquals(exactAsset.profileCmsBytes),
      );
      for (final framework in [appFramework, flutterFramework]) {
        expect(
          File(p.join(framework, 'embedded.mobileprovision')).existsSync(),
          isFalse,
        );
        expect(
          File(p.join(framework, '_CodeSignature', 'stale')).existsSync(),
          isFalse,
        );
      }
      expect(
        File(p.join(app.path, '_CodeSignature', 'stale')).existsSync(),
        isFalse,
      );

      final rootResourcesFile = File(
        p.join(app.path, '_CodeSignature', 'CodeResources'),
      );
      final rootResourcesBytes = rootResourcesFile.readAsBytesSync();
      expect(utf8.decode(rootResourcesBytes), startsWith('<?xml'));
      final rootResources = _plist(rootResourcesBytes);
      final files = _map(rootResources['files']);
      final files2 = _map(rootResources['files2']);
      expect(files, isNot(contains('Runner')));
      expect(files2, isNot(contains('Runner')));
      expect(files, isNot(contains('_CodeSignature/stale')));
      expect(files2, isNot(contains('_CodeSignature/stale')));
      expect(
        _bytes(files['resource.txt']),
        orderedEquals(sha1.convert(utf8.encode('resource')).bytes),
      );
      expect(
        _bytes(_map(files2['resource.txt'])['hash2']),
        orderedEquals(sha256.convert(utf8.encode('resource')).bytes),
      );
      expect(_map(files['Base.lproj/Localizable.strings'])['optional'], isTrue);
      expect(
        _map(files2['Base.lproj/Localizable.strings'])['optional'],
        isTrue,
      );

      final appExecutable = File(p.join(appFramework, 'App')).readAsBytesSync();
      expect(
        _bytes(files['Frameworks/App.framework/App']),
        orderedEquals(sha1.convert(appExecutable).bytes),
      );
      final appSeal = _map(files2['Frameworks/App.framework/App']);
      expect(
        _bytes(appSeal['hash']),
        orderedEquals(sha1.convert(appExecutable).bytes),
      );
      expect(
        _bytes(appSeal['hash2']),
        orderedEquals(sha256.convert(appExecutable).bytes),
      );
      expect(files2, isNot(contains('Frameworks/App.framework')));

      final pluginPath = p.join(app.path, 'Frameworks', 'plugin.dylib');
      final pluginBytes = File(pluginPath).readAsBytesSync();
      expect(
        _bytes(files['Frameworks/plugin.dylib']),
        orderedEquals(sha1.convert(pluginBytes).bytes),
      );
      final pluginSeal = _map(files2['Frameworks/plugin.dylib']);
      expect(
        _bytes(pluginSeal['hash']),
        orderedEquals(sha1.convert(pluginBytes).bytes),
      );
      expect(
        _bytes(pluginSeal['hash2']),
        orderedEquals(sha256.convert(pluginBytes).bytes),
      );

      final rules = _map(rootResources['rules']);
      final rules2 = _map(rootResources['rules2']);
      expect(rules['^.*'], isTrue);
      expect(_map(rules[r'^.*\.lproj/'])['weight'], 1000.0);
      expect(_map(rules2[r'^Info\.plist$'])['omit'], isTrue);
      expect(_map(rules2[r'^(.*/)?\.DS_Store$'])['weight'], 2000.0);

      final frameworkResources = _plist(
        File(
          p.join(appFramework, '_CodeSignature', 'CodeResources'),
        ).readAsBytesSync(),
      );
      expect(_map(frameworkResources['files']), isNot(contains('App')));
      expect(_map(frameworkResources['files2']), isNot(contains('App')));

      expect(
        _entitlements(File(p.join(app.path, 'Runner')).readAsBytesSync()),
        containsPair('application-identifier', 'TESTTEAM123.dev.xcross.Runner'),
      );
      expect(_entitlements(appExecutable), isEmpty);
      expect(_entitlements(pluginBytes), isEmpty);

      final first = <String, Uint8List>{
        for (final path in [
          p.join(app.path, 'Runner'),
          p.join(appFramework, 'App'),
          p.join(flutterFramework, 'Flutter'),
          pluginPath,
          rootResourcesFile.path,
          p.join(appFramework, '_CodeSignature', 'CodeResources'),
          p.join(flutterFramework, '_CodeSignature', 'CodeResources'),
        ])
          path: File(path).readAsBytesSync(),
      };
      await signer.signApp(app.path, signingTime: signingTime);
      for (final entry in first.entries) {
        expect(
          File(entry.key).readAsBytesSync(),
          orderedEquals(entry.value),
          reason: entry.key,
        );
      }

      File(p.join(app.path, 'resource.txt')).writeAsStringSync('tampered');
      expect(
        _bytes(
          _map(
            _plist(rootResourcesFile.readAsBytesSync())['files'],
          )['resource.txt'],
        ),
        isNot(orderedEquals(sha1.convert(utf8.encode('tampered')).bytes)),
      );
    },
  );

  test(
    'accepts wildcard profiles and rejects incompatible exact profiles',
    () async {
      final wildcardApp = _app(
        temporaryDirectory,
        'wildcard-app',
        'dev.xcross.Wildcard',
      );
      await BundleSigner(wildcardAsset).preflight(wildcardApp.path);

      await expectLater(
        BundleSigner(exactAsset).preflight(wildcardApp.path),
        throwsA(
          isA<XcrossError>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('dev.xcross.Wildcard'),
              contains('TESTTEAM123.dev.xcross.Runner'),
            ),
          ),
        ),
      );
    },
  );

  test('seals safe symlink targets and rejects out-of-tree targets', () async {
    final safeApp = _app(temporaryDirectory, 'safe-link', 'dev.xcross.Runner');
    File(p.join(safeApp.path, 'target.txt')).writeAsStringSync('target');
    if (!_link(p.join(safeApp.path, 'alias.txt'), 'target.txt')) {
      markTestSkipped('symbolic links are unavailable on this host');
      return;
    }
    await BundleSigner(
      exactAsset,
    ).signApp(safeApp.path, signingTime: signingTime);
    final resources = _plist(
      File(
        p.join(safeApp.path, '_CodeSignature', 'CodeResources'),
      ).readAsBytesSync(),
    );
    expect(
      _map(_map(resources['files'])['alias.txt'])['symlink'],
      'target.txt',
    );
    expect(
      _map(_map(resources['files2'])['alias.txt'])['symlink'],
      'target.txt',
    );

    final unsafeApp = _app(
      temporaryDirectory,
      'unsafe-link',
      'dev.xcross.Runner',
    );
    final outside = File(p.join(temporaryDirectory.path, 'outside.txt'))
      ..writeAsStringSync('outside');
    expect(_link(p.join(unsafeApp.path, 'escape'), outside.path), isTrue);
    await expectLater(
      BundleSigner(exactAsset).preflight(unsafeApp.path),
      throwsA(
        isA<XcrossError>().having(
          (error) => error.message,
          'message',
          allOf(contains('escape'), contains('escapes')),
        ),
      ),
    );
  });

  test('rejects unsupported nested bundles before any mutation', () async {
    final app = _app(temporaryDirectory, 'unsupported', 'dev.xcross.Runner');
    final profile = File(p.join(app.path, 'embedded.mobileprovision'))
      ..writeAsStringSync('old-profile');
    final signature = File(p.join(app.path, '_CodeSignature', 'old'))
      ..createSync(recursive: true);
    signature.writeAsStringSync('old-signature');
    final runner = File(p.join(app.path, 'Runner'));
    final runnerBefore = runner.readAsBytesSync();
    Directory(
      p.join(app.path, 'PlugIns', 'Bad.appex'),
    ).createSync(recursive: true);

    await expectLater(
      BundleSigner(exactAsset).signApp(app.path, signingTime: signingTime),
      throwsA(
        isA<XcrossError>().having(
          (error) => error.message,
          'message',
          contains('PlugIns'),
        ),
      ),
    );
    expect(profile.readAsStringSync(), 'old-profile');
    expect(signature.readAsStringSync(), 'old-signature');
    expect(runner.readAsBytesSync(), orderedEquals(runnerBefore));

    final unknown = _app(
      temporaryDirectory,
      'unknown-bundle',
      'dev.xcross.Runner',
    );
    final hiddenCode = Directory(p.join(unknown.path, 'HiddenCode'))
      ..createSync();
    _writeInfo(hiddenCode.path, 'Hidden', 'dev.xcross.Hidden');
    File(p.join(hiddenCode.path, 'Hidden')).writeAsStringSync('not Mach-O');
    await expectLater(
      BundleSigner(exactAsset).preflight(unknown.path),
      throwsA(
        isA<XcrossError>().having(
          (error) => error.message,
          'message',
          allOf(
            contains('HiddenCode'),
            contains('unsupported nested code bundle'),
          ),
        ),
      ),
    );
  });

  test('preflights every loose Mach-O before any mutation', () async {
    final app = _app(temporaryDirectory, 'bad-macho', 'dev.xcross.Runner');
    final profile = File(p.join(app.path, 'embedded.mobileprovision'))
      ..writeAsStringSync('old-profile');
    final runner = File(p.join(app.path, 'Runner'));
    final runnerBefore = runner.readAsBytesSync();
    File(
      p.join(app.path, 'Frameworks', 'bad.dylib'),
    ).writeAsBytesSync([0xca, 0xfe, 0xba, 0xbe]);

    await expectLater(
      BundleSigner(exactAsset).signApp(app.path, signingTime: signingTime),
      throwsA(
        isA<XcrossError>().having(
          (error) => error.message,
          'message',
          allOf(contains('Frameworks/bad.dylib'), contains('FAT')),
        ),
      ),
    );
    expect(profile.readAsStringSync(), 'old-profile');
    expect(runner.readAsBytesSync(), orderedEquals(runnerBefore));
  });

  test('requires an app directory and complete bundle metadata', () async {
    final file = File(p.join(temporaryDirectory.path, 'input.ipa'))
      ..writeAsStringSync('ipa');
    await expectLater(
      BundleSigner(exactAsset).preflight(file.path),
      throwsA(
        isA<XcrossError>().having(
          (error) => error.message,
          'message',
          contains('.app directory'),
        ),
      ),
    );

    final app = Directory(p.join(temporaryDirectory.path, 'missing.app'))
      ..createSync();
    await expectLater(
      BundleSigner(exactAsset).preflight(app.path),
      throwsA(
        isA<XcrossError>().having(
          (error) => error.message,
          'message',
          contains('Info.plist'),
        ),
      ),
    );
  });
}

Directory _app(Directory parent, String name, String identifier) {
  final app = Directory(p.join(parent.path, '$name.app'))..createSync();
  _writeInfo(app.path, 'Runner', identifier);
  File(p.join(app.path, 'Runner')).writeAsBytesSync(_macho());
  final frameworks = Directory(p.join(app.path, 'Frameworks'))..createSync();
  _framework(frameworks.path, 'App', 'dev.xcross.App');
  _framework(frameworks.path, 'Flutter', 'io.flutter.Flutter');
  File(
    p.join(frameworks.path, 'plugin.dylib'),
  ).writeAsBytesSync(_macho(fileType: _mhDylib));
  return app;
}

void _framework(String frameworks, String name, String identifier) {
  final directory = Directory(p.join(frameworks, '$name.framework'))
    ..createSync();
  _writeInfo(directory.path, name, identifier);
  File(
    p.join(directory.path, name),
  ).writeAsBytesSync(_macho(fileType: _mhDylib));
  File(p.join(directory.path, 'asset.txt')).writeAsStringSync('$name asset');
}

void _writeInfo(String directory, String executable, String identifier) {
  File(p.join(directory, 'Info.plist')).writeAsStringSync(
    PropertyListSerialization.stringWithPropertyList({
      'CFBundleExecutable': executable,
      'CFBundleIdentifier': identifier,
    }),
  );
}

Map<Object?, Object?> _plist(List<int> bytes) {
  final data = Uint8List.fromList(bytes);
  return _map(
    bytes.length >= 8 && ascii.decode(bytes.sublist(0, 8)) == 'bplist00'
        ? PropertyListSerialization.propertyListWithData(
            ByteData.sublistView(data),
          )
        : PropertyListSerialization.propertyListWithString(utf8.decode(data)),
  );
}

Map<Object?, Object?> _map(Object? value) => value! as Map<Object?, Object?>;

Uint8List _bytes(Object? value) {
  final data = value! as ByteData;
  return Uint8List.fromList(
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
  );
}

Map<Object?, Object?> _entitlements(Uint8List bytes) {
  final slots = _signatureSlots(bytes);
  final blob = slots[5]!;
  return _map(
    PropertyListSerialization.propertyListWithString(
      utf8.decode(blob.sublist(8)),
    ),
  );
}

Map<int, Uint8List> _signatureSlots(Uint8List bytes) {
  var command = 32;
  int? signatureOffset;
  for (var index = 0; index < _u32le(bytes, 16); index++) {
    if (_u32le(bytes, command) == 0x1d) {
      signatureOffset = _u32le(bytes, command + 8);
      break;
    }
    command += _u32le(bytes, command + 4);
  }
  if (signatureOffset == null) throw StateError('LC_CODE_SIGNATURE missing');
  final count = _u32be(bytes, signatureOffset + 8);
  final result = <int, Uint8List>{};
  for (var index = 0; index < count; index++) {
    final type = _u32be(bytes, signatureOffset + 12 + index * 8);
    final offset =
        signatureOffset + _u32be(bytes, signatureOffset + 16 + index * 8);
    final length = _u32be(bytes, offset + 4);
    result[type] = Uint8List.sublistView(bytes, offset, offset + length);
  }
  return result;
}

bool _link(String path, String target) {
  try {
    Link(path).createSync(target);
    return true;
  } on FileSystemException {
    return false;
  }
}

Uint8List _macho({int fileType = _mhExecute}) {
  const sizeofcmds = 152 + 72;
  const commandSlack = 16;
  const linkeditOffset = 4096;
  const commandsEnd = 32 + sizeofcmds;
  const textOffset = commandsEnd + commandSlack;
  final bytes = Uint8List(linkeditOffset);
  _setU32le(bytes, 0, 0xfeedfacf);
  _setU32le(bytes, 4, 0x0100000c);
  _setU32le(bytes, 12, fileType);
  _setU32le(bytes, 16, 2);
  _setU32le(bytes, 20, sizeofcmds);

  var command = 32;
  _setU32le(bytes, command, 0x19);
  _setU32le(bytes, command + 4, 152);
  _name(bytes, command + 8, '__TEXT');
  _setU64le(bytes, command + 32, linkeditOffset);
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
  _setU32le(bytes, command, 0x19);
  _setU32le(bytes, command + 4, 72);
  _name(bytes, command + 8, '__LINKEDIT');
  _setU64le(bytes, command + 24, linkeditOffset);
  _setU64le(bytes, command + 40, linkeditOffset);
  _setU32le(bytes, command + 56, 7);
  _setU32le(bytes, command + 60, 1);
  return bytes;
}

Future<SigningAsset> _signingAsset(
  Directory directory,
  String name,
  String applicationIdentifier,
) {
  final fixture = Directory(p.join(directory.path, name))..createSync();
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
      'application-identifier': applicationIdentifier,
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
  final keyPath = p.join(fixture.path, 'key.pem');
  final certificatePath = p.join(fixture.path, 'certificate.pem');
  final profilePath = p.join(fixture.path, 'profile.mobileprovision');
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

void _name(Uint8List bytes, int offset, String value) {
  bytes.setRange(offset, offset + value.length, ascii.encode(value));
}

const _mhExecute = 2;
const _mhDylib = 6;

int _u32le(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes).getUint32(offset, Endian.little);

int _u32be(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes).getUint32(offset);

void _setU32le(Uint8List bytes, int offset, int value) =>
    ByteData.sublistView(bytes).setUint32(offset, value, Endian.little);

void _setU64le(Uint8List bytes, int offset, int value) =>
    ByteData.sublistView(bytes).setUint64(offset, value, Endian.little);
