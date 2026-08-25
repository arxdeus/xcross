import 'dart:io';
import 'dart:typed_data';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;

const _fatMachOMagics = <int>{
  0xcafebabe, // FAT_MAGIC
  0xbebafeca, // FAT_CIGAM
  0xcafebabf, // FAT_MAGIC_64
  0xbfbafeca, // FAT_CIGAM_64
};

List<String> collectNativeAssetFrameworks(String outputDirectory) {
  final directory = Directory(p.join(outputDirectory, 'native_assets'));
  if (!directory.existsSync()) return <String>[];
  return directory
      .listSync()
      .whereType<Directory>()
      .where((entry) => entry.path.endsWith('.framework'))
      .map((entry) => entry.path)
      .toList();
}

Future<bool> isFatMachO(String path) async {
  final file = File(path);
  if (!file.existsSync() || await file.length() < 4) return false;
  final bytes = await file.openRead(0, 4).expand((chunk) => chunk).toList();
  final magic = ByteData.sublistView(Uint8List.fromList(bytes)).getUint32(0);
  return _fatMachOMagics.contains(magic);
}

Future<void> thinFrameworksToArm64(
  Iterable<String> frameworks, {
  required String lipo,
}) async {
  for (final framework in frameworks) {
    final binary = p.join(framework, p.basenameWithoutExtension(framework));
    if (!await isFatMachO(binary)) continue;

    final thin = '$binary.xcross-thin';
    try {
      await ProcessRunner.runChecked(lipo, [
        '-thin',
        'arm64',
        binary,
        '-output',
        thin,
      ], label: 'llvm-lipo');
      // File.rename cannot replace an existing file on Windows. copy() can,
      // and keeps the original intact until lipo has completed successfully.
      await File(thin).copy(binary);
    } finally {
      final temporary = File(thin);
      if (temporary.existsSync()) await temporary.delete();
    }
  }
}
