import 'dart:io';
import 'dart:typed_data';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/apple/mach_o.dart';
import 'package:xcross/src/shared/apple/mach_o_code_signature.dart';
import 'package:xcross/src/shared/flutter/errors.dart';

@internal
final class AdHocSignatureRefresher {
  const AdHocSignatureRefresher(this.fileSystem, this.paths);

  final HostFileSystemInterface fileSystem;
  final p.Context paths;

  Future<List<String>> refresh(String bundleDir) async {
    final refreshed = <String>[];
    final entities = fileSystem
        .directory(bundleDir)
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .toList();
    for (final entity in entities) {
      if (!await _isThinMachO(entity)) continue;
      final bytes = await entity.readAsBytes();
      final changed = MachOCodeSignature.refreshAdHocPageHashes(
        bytes,
        invalid: (message) =>
            throw FlutterBuildError('${entity.path}: invalid Mach-O: $message'),
      );
      if (!changed) continue;
      await entity.writeAsBytes(bytes, flush: true);
      refreshed.add(paths.relative(entity.path, from: bundleDir));
    }
    return refreshed;
  }

  static Future<bool> _isThinMachO(File file) async {
    if (await file.length() < MachOConstants.headerSize64) return false;
    final header = await file.openRead(0, 4).expand((chunk) => chunk).toList();
    return ByteData.sublistView(
          Uint8List.fromList(header),
        ).getUint32(0, Endian.little) ==
        MachOConstants.magic64;
  }
}
