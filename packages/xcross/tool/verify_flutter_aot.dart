import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/apple/mach_o.dart';

const _usage =
    'usage: verify_flutter_aot.dart <xcross-ios dir, .app or digests .json> '
    '[--write=<json>] [--expect=<json> [--sections=<key>,...]] '
    '[--dsym=required|optional]';

const _lcUuid = 0x1b;

/// Checks a precompiled (profile or release) xcross build.
///
/// `verify_flutter_aot.dart <xcross-ios dir or .app> --write=<json>` records
/// SHA-256 digests of `App.framework/App`'s `__text` (Dart machine code) and
/// `__const` (snapshot data) and of `Flutter.framework/Flutter`'s `__text`
/// (`Flutter.__text`, which tells the profile and release engines apart and
/// is untouched by code signing).
///
/// `--expect=<json>` compares the digests of the app, or of a digests `.json`
/// recorded earlier, against digests recorded from an official
/// `flutter build ios`. `--sections=__text,Flutter.__text` limits the
/// comparison (profile snapshots embed the SDK's absolute `file:` URIs in
/// `__const`). Every compared digest must be a SHA-256 on both sides.
///
/// `--dsym=required` demands `App.framework.dSYM` next to the `.app` with the
/// LC_UUID of the packaged `App.framework/App`; `--dsym=optional` only checks
/// the UUID when the dSYM exists.
void main(List<String> arguments) {
  final positional = arguments.where((a) => !a.startsWith('--')).toList();
  if (positional.length != 1) throw ArgumentError(_usage);
  String? option(String name) {
    for (final argument in arguments) {
      if (argument.startsWith('--$name=')) {
        return argument.substring(name.length + 3);
      }
    }
    return null;
  }

  final known = {'write', 'expect', 'sections', 'dsym'};
  for (final argument in arguments.where((a) => a.startsWith('--'))) {
    final name = argument.substring(2).split('=').first;
    if (!known.contains(name) || !argument.contains('=')) {
      throw ArgumentError('Unknown option $argument\n$_usage');
    }
  }
  final dsym = option('dsym');
  if (dsym != null && dsym != 'required' && dsym != 'optional') {
    throw ArgumentError('--dsym must be required or optional\n$_usage');
  }

  final input = positional.single;
  final Map<String, String> digests;
  if (input.endsWith('.json')) {
    if (option('write') != null || dsym != null) {
      throw ArgumentError('A digests .json only supports --expect\n$_usage');
    }
    digests = _readDigests(input);
  } else {
    digests = _verifyApp(input, dsym: dsym);
  }

  if (option('write') case final path?) {
    File(
      path,
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(digests));
  }
  if (option('expect') case final path?) {
    final expected = _readDigests(path);
    final compared = option('sections')?.split(',') ?? expected.keys.toList();
    if (compared.isEmpty || compared.any((key) => key.isEmpty)) {
      throw StateError('No digests to compare in $path');
    }
    for (final key in compared) {
      final want = expected[key];
      final got = digests[key];
      if (!_isSha256(want)) {
        throw StateError('$path has no SHA-256 for $key: $want');
      }
      if (!_isSha256(got)) {
        throw StateError('$input has no SHA-256 for $key: $got');
      }
      if (got != want) {
        throw StateError(
          '$key of $input differs from flutter build ios ($path): '
          '$got != $want',
        );
      }
    }
    stdout.writeln('$input matches $path for ${compared.join(', ')}');
  }
  stdout.writeln('Verified precompiled build: ${jsonEncode(digests)}');
}

bool _isSha256(String? value) =>
    value != null && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

Map<String, String> _readDigests(String path) {
  final file = File(path);
  if (!file.existsSync()) throw StateError('Missing digests file $path');
  final Object? decoded;
  try {
    decoded = jsonDecode(file.readAsStringSync());
  } on FormatException catch (error) {
    throw StateError('$path is not JSON: ${error.message}');
  }
  if (decoded is! Map) throw StateError('$path is not a JSON object');
  return {
    for (final MapEntry(:key, :value) in decoded.entries)
      if (key is String && value is String) key: value,
  };
}

Map<String, String> _verifyApp(String path, {String? dsym}) {
  final app = _findApp(path);
  final framework = Directory.fromUri(
    app.uri.resolve('Frameworks/App.framework/'),
  );
  final assets = Directory.fromUri(framework.uri.resolve('flutter_assets/'));
  for (final jitOnly in [
    'kernel_blob.bin',
    'vm_snapshot_data',
    'isolate_snapshot_data',
  ]) {
    if (File.fromUri(assets.uri.resolve(jitOnly)).existsSync()) {
      throw StateError('Precompiled app still bundles $jitOnly');
    }
  }

  final binary = File.fromUri(framework.uri.resolve('App'));
  final appFile = ArmMachO.read(binary.path);
  if (appFile.file.fileType != MachOConstants.mhDylib) {
    appFile.invalid('expected a dylib');
  }
  final names = appFile.symbolNames();
  for (final symbol in ['_kDartSnapshotText', '_kDartSnapshotData']) {
    if (!names.contains(symbol)) appFile.invalid('missing $symbol');
  }
  final digests = {
    '__text': appFile.sectionDigest('__TEXT', '__text'),
    '__const': appFile.sectionDigest('__TEXT', '__const'),
  };

  final engine = File.fromUri(
    app.uri.resolve('Frameworks/Flutter.framework/Flutter'),
  );
  final engineFile = ArmMachO.read(engine.path);
  final engineText = latin1.decode(engineFile.bytes, allowInvalid: true);
  if (!engineText.contains('AOT runtime cannot run a JIT snapshot')) {
    throw StateError('${engine.path} is not a precompiled-mode engine');
  }
  digests['Flutter.__text'] = engineFile.sectionDigest('__TEXT', '__text');

  if (dsym != null) {
    final dwarf = File.fromUri(
      app.parent.uri.resolve('App.framework.dSYM/Contents/Resources/DWARF/App'),
    );
    if (dwarf.existsSync()) {
      final expected = appFile.uuid();
      final actual = ArmMachO.read(dwarf.path).uuid();
      if (actual != expected) {
        throw StateError(
          'LC_UUID of ${dwarf.path} ($actual) does not match '
          '${binary.path} ($expected)',
        );
      }
      stdout.writeln('Verified ${dwarf.path} (LC_UUID $actual)');
    } else if (dsym == 'required') {
      throw StateError('Missing dSYM ${dwarf.path}');
    } else {
      stdout.writeln('No dSYM at ${dwarf.path}; skipped the LC_UUID check');
    }
  }
  return digests;
}

Directory _findApp(String path) {
  if (path.endsWith('.app')) return Directory(path);
  final directory = Directory(path);
  if (!directory.existsSync()) throw StateError('Missing directory $path');
  final apps = directory
      .listSync()
      .whereType<Directory>()
      .where((directory) => directory.path.endsWith('.app'))
      .toList();
  if (apps.length != 1) {
    throw StateError('Expected one .app in $path, found ${apps.length}');
  }
  return apps.single;
}

/// The arm64 slice of a thin or universal (32- or 64-bit fat header) Mach-O.
@internal
final class ArmMachO {
  ArmMachO._(this.path, this.bytes, this.file);

  factory ArmMachO.read(String path) {
    final source = File(path);
    if (!source.existsSync()) throw StateError('Missing Mach-O file $path');
    Never invalid(String message) => throw StateError('$path: $message');
    final bytes = _arm64Slice(source.readAsBytesSync(), invalid);
    final file = MachOFile.parse(bytes, invalid: invalid);
    if (file.cpuType != MachOConstants.cpuTypeArm64) {
      invalid('expected an arm64 Mach-O');
    }
    return ArmMachO._(path, bytes, file);
  }

  final String path;
  final Uint8List bytes;
  final MachOFile file;

  Never invalid(String message) => throw StateError('$path: $message');

  MachOLoadCommand command(int type, String name) {
    for (final command in file.commands) {
      if (command.type == type) return command;
    }
    invalid('missing $name');
  }

  Set<String> symbolNames() {
    final symbols = file.parseSymbolTable(
      command(MachOConstants.lcSymtab, 'LC_SYMTAB'),
    );
    return {
      for (var index = 0; index < symbols.symbolCount; index++)
        symbols.symbolName(index, symbols.symbolAt(index)),
    };
  }

  String sectionDigest(String segment, String name) {
    final sections = file.parseSections(
      file.commands.where(
        (command) => command.type == MachOConstants.lcSegment64,
      ),
    );
    for (final section in sections) {
      if (section.segment == segment && section.name == name) {
        return sha256
            .convert(
              Uint8List.sublistView(
                bytes,
                section.fileOffset,
                section.fileOffset + section.size,
              ),
            )
            .toString();
      }
    }
    invalid('missing $segment,$name');
  }

  String uuid() {
    final uuid = command(_lcUuid, 'LC_UUID');
    if (uuid.size < 24) invalid('LC_UUID is shorter than 24 bytes');
    final hex = [
      for (final byte in bytes.sublist(uuid.offset + 8, uuid.offset + 24))
        byte.toRadixString(16).padLeft(2, '0'),
    ].join().toUpperCase();
    return [
      hex.substring(0, 8),
      hex.substring(8, 12),
      hex.substring(12, 16),
      hex.substring(16, 20),
      hex.substring(20),
    ].join('-');
  }
}

Uint8List _arm64Slice(Uint8List bytes, Never Function(String) invalid) {
  if (bytes.length < 8) invalid('truncated header');
  final data = ByteData.sublistView(bytes);
  final magic = data.getUint32(0);
  final int entrySize;
  if (magic == 0xCAFEBABE) {
    entrySize = 20;
  } else if (magic == 0xCAFEBABF) {
    entrySize = 32;
  } else {
    return bytes;
  }
  final count = data.getUint32(4);
  for (var index = 0; index < count; index++) {
    final entry = 8 + index * entrySize;
    if (entry + entrySize > bytes.length) {
      invalid('truncated universal header');
    }
    if (data.getUint32(entry) != MachOConstants.cpuTypeArm64) continue;
    final offset = entrySize == 20
        ? data.getUint32(entry + 8)
        : data.getUint64(entry + 8);
    final size = entrySize == 20
        ? data.getUint32(entry + 12)
        : data.getUint64(entry + 16);
    if (!MachOFile.rangeFits(offset, size, bytes.length)) {
      invalid('arm64 slice exceeds file');
    }
    return Uint8List.sublistView(bytes, offset, offset + size);
  }
  invalid('universal binary has no arm64 slice');
}
