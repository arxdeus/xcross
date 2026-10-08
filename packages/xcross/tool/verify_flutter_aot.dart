import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:xcross/src/shared/apple/mach_o.dart';

/// Checks a precompiled (profile or release) xcross build.
///
/// `verify_flutter_aot.dart <xcross-ios dir> --write=<json>` records the
/// digests of `App.framework/App`'s code and data sections. With
/// `--expect=<json>` it compares them against digests recorded from an
/// official `flutter build ios`; `--sections=__text` limits the comparison
/// (profile snapshots embed the SDK's absolute `file:` URIs in `__const`).
void main(List<String> arguments) {
  final positional = arguments.where((a) => !a.startsWith('--')).toList();
  if (positional.length != 1) {
    throw ArgumentError(
      'usage: verify_flutter_aot.dart <app dir or .app> '
      '[--write=<json>] [--expect=<json>]',
    );
  }
  String? option(String name) {
    for (final argument in arguments) {
      if (argument.startsWith('--$name=')) {
        return argument.substring(name.length + 3);
      }
    }
    return null;
  }

  final app = _findApp(positional.single);
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
  final digests = sectionDigests(binary.readAsBytesSync());

  final flutter = File.fromUri(
    app.uri.resolve('Frameworks/Flutter.framework/Flutter'),
  );
  final engine = latin1.decode(flutter.readAsBytesSync(), allowInvalid: true);
  if (!engine.contains('AOT runtime cannot run a JIT snapshot')) {
    throw StateError('${flutter.path} is not a precompiled-mode engine');
  }

  if (option('write') case final path?) {
    File(
      path,
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(digests));
  }
  if (option('expect') case final path?) {
    final expected = (jsonDecode(File(path).readAsStringSync()) as Map)
        .cast<String, Object?>();
    final compared = option('sections')?.split(',') ?? expected.keys;
    for (final key in compared) {
      final value = expected[key];
      if (value == null || digests[key] != value) {
        throw StateError(
          '$key of ${binary.path} differs from flutter build ios: '
          '${digests[key]} != $value',
        );
      }
    }
  }
  stdout.writeln('Verified precompiled App.framework: ${jsonEncode(digests)}');
}

Directory _findApp(String path) {
  if (path.endsWith('.app')) return Directory(path);
  final apps = Directory(path)
      .listSync()
      .whereType<Directory>()
      .where((directory) => directory.path.endsWith('.app'))
      .toList();
  if (apps.length != 1) {
    throw StateError('Expected one .app in $path, found ${apps.length}');
  }
  return apps.single;
}

/// SHA-256 of `__TEXT,__text` (Dart machine code) and `__TEXT,__const` (the
/// snapshot) of an arm64 App dylib exporting the two Dart snapshot symbols.
/// flutter build ios wraps the dylib in a one-architecture universal binary.
Map<String, String> sectionDigests(Uint8List input) {
  Never invalid(String message) => throw StateError('App: $message');
  final bytes = _arm64Slice(input, invalid);
  final file = MachOFile.parse(bytes, invalid: invalid);
  if (file.cpuType != MachOConstants.cpuTypeArm64 ||
      file.fileType != MachOConstants.mhDylib) {
    invalid('expected an arm64 dylib');
  }
  final segments = file.commands.where(
    (command) => command.type == MachOConstants.lcSegment64,
  );
  final symbols = file.parseSymbolTable(
    file.commands.singleWhere(
      (command) => command.type == MachOConstants.lcSymtab,
    ),
  );
  final names = {
    for (var index = 0; index < symbols.symbolCount; index++)
      symbols.symbolName(index, symbols.symbolAt(index)),
  };
  for (final symbol in ['_kDartSnapshotText', '_kDartSnapshotData']) {
    if (!names.contains(symbol)) invalid('missing $symbol');
  }
  final digests = <String, String>{};
  for (final section in file.parseSections(segments)) {
    if (section.segment == '__TEXT' &&
        (section.name == '__text' || section.name == '__const')) {
      digests[section.name] = sha256
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
  if (digests.length != 2) invalid('missing __text or __const');
  return digests;
}

Uint8List _arm64Slice(Uint8List bytes, Never Function(String) invalid) {
  if (bytes.length < 8) invalid('truncated header');
  final data = ByteData.sublistView(bytes);
  if (data.getUint32(0) != 0xCAFEBABE) return bytes;
  final count = data.getUint32(4);
  for (var index = 0; index < count; index++) {
    final entry = 8 + index * 20;
    if (entry + 20 > bytes.length) invalid('truncated universal header');
    if (data.getUint32(entry) != MachOConstants.cpuTypeArm64) continue;
    final offset = data.getUint32(entry + 8);
    final size = data.getUint32(entry + 12);
    if (offset + size > bytes.length) invalid('arm64 slice exceeds file');
    return Uint8List.sublistView(bytes, offset, offset + size);
  }
  invalid('universal binary has no arm64 slice');
}
