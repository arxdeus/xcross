import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/compose/kotlin_native_class_patches.dart';
import 'package:xcross/src/shared/compose/kotlin_native_entries.dart';

int _le2(Uint8List buf, int off) => buf[off] | (buf[off + 1] << 8);

int _le4(Uint8List buf, int off) =>
    buf[off] |
    (buf[off + 1] << 8) |
    (buf[off + 2] << 16) |
    (buf[off + 3] << 24);

void _rejectDuplicateZipEntries(Uint8List bytes) {
  final eocdOffset = _findEndOfCentralDirectory(bytes);
  if (eocdOffset == null) return;
  final entryCount = _le2(bytes, eocdOffset + 10);
  final centralDirectorySize = _le4(bytes, eocdOffset + 12);
  final centralDirectoryOffset = _le4(bytes, eocdOffset + 16);
  final centralDirectoryEnd = centralDirectoryOffset + centralDirectorySize;
  if (centralDirectoryOffset < 0 || centralDirectoryEnd > bytes.length) return;

  final names = <String>{};
  var off = centralDirectoryOffset;
  for (var i = 0; i < entryCount && off < centralDirectoryEnd; i++) {
    if (_le4(bytes, off) != 0x02014B50) return;
    final nameLength = _le2(bytes, off + 28);
    final extraLength = _le2(bytes, off + 30);
    final commentLength = _le2(bytes, off + 32);
    final nameStart = off + 46;
    final nameEnd = nameStart + nameLength;
    if (nameEnd > centralDirectoryEnd) return;
    final name = utf8.decode(
      Uint8List.sublistView(bytes, nameStart, nameEnd),
      allowMalformed: true,
    );
    if (!names.add(name)) {
      throw StateError('HostManagerPatcher: duplicate JAR entry $name');
    }
    off = nameEnd + extraLength + commentLength;
  }
}

int? _findEndOfCentralDirectory(Uint8List bytes) {
  final minOffset = bytes.length > 0xFFFF + 22 ? bytes.length - 0xFFFF - 22 : 0;
  for (var off = bytes.length - 22; off >= minOffset; off--) {
    if (_le4(bytes, off) == 0x06054B50) return off;
  }
  return null;
}

void _addUnmodifiedEntry(ZipEncoder encoder, ArchiveFile entry) {
  final decodedTime = entry.lastModDateTime;
  entry.lastModTime =
      DateTime(
        decodedTime.year,
        decodedTime.month,
        decodedTime.day,
        decodedTime.hour,
        decodedTime.minute,
        decodedTime.second,
      ).millisecondsSinceEpoch ~/
      1000;
  encoder.add(entry);
}

@internal
final class KotlinNativeJarPatcher {
  const KotlinNativeJarPatcher(this.files);
  final HostFileSystemInterface files;
  bool patch(String jarPath) {
    final jarExists = files.file(jarPath).existsSync();
    if (!jarExists) {
      return false;
    }

    final tmpPath = '$jarPath.xcross-tmp';
    final jarBytes = files.file(jarPath).readAsBytesSync();
    _rejectDuplicateZipEntries(jarBytes);
    try {
      final archive = ZipDecoder().decodeBytes(jarBytes);
      final names = <String>{};
      for (final entry in archive.files) {
        if (!names.add(entry.name)) {
          throw StateError(
            'HostManagerPatcher: duplicate JAR entry ${entry.name}',
          );
        }
      }

      // Check idempotency marker.
      if (archive.files.any((f) => f.name == jarMarkerPath)) {
        return false;
      }

      final hasHm = archive.files.any((f) => f.name == hostManagerClassEntry);
      final hasObjC = archive.files.any((f) => f.name == objcExportClassEntry);
      final hasAcfg = archive.files.any(
        (f) => f.name == appleConfigurablesImplClassEntry,
      );
      if (!hasHm && !hasObjC && !hasAcfg) {
        return false;
      }

      // Rebuild the archive with patched entries, streaming to a temp file.
      final output = OutputFileStream(files.file(tmpPath).path);
      final encoder = ZipEncoder();
      encoder.startEncode(output);
      var didPatch = false;

      try {
        for (final entry in archive.files) {
          final name = entry.name;

          if (name == hostManagerClassEntry) {
            final patched = patchHostManagerClassBytes(entry.readBytes()!);
            encoder.add(ArchiveFile(name, patched.length, patched));
            didPatch = true;
          } else if (name == objcExportClassEntry) {
            final patched = patchObjCExportClassBytes(entry.readBytes()!);
            if (patched != null) {
              encoder.add(ArchiveFile(name, patched.length, patched));
              didPatch = true;
            } else {
              _addUnmodifiedEntry(encoder, entry);
            }
          } else if (name == appleConfigurablesImplClassEntry) {
            final patched = patchAppleConfigurablesImplClassBytes(
              entry.readBytes()!,
            );
            if (patched != null) {
              encoder.add(ArchiveFile(name, patched.length, patched));
              didPatch = true;
            } else {
              _addUnmodifiedEntry(encoder, entry);
            }
          } else {
            _addUnmodifiedEntry(encoder, entry);
          }
        }

        if (!didPatch) {
          encoder.endEncode();
          output.closeSync();
          final tmp = files.file(tmpPath);
          final tmpExists = tmp.existsSync();
          if (tmpExists) tmp.deleteSync();
          return false;
        }

        // Write idempotency marker.
        final markerBytes = utf8.encode('patched\n');
        encoder.add(
          ArchiveFile(jarMarkerPath, markerBytes.length, markerBytes),
        );
        encoder.endEncode();
      } on Object catch (_) {
        try {
          output.closeSync();
        } on Object catch (_) {}
        final tmp = files.file(tmpPath);
        final tmpExists = tmp.existsSync();
        if (tmpExists) tmp.deleteSync();
        rethrow;
      }

      output.closeSync();

      // Atomic replace.
      files.file(tmpPath).renameSync(files.file(jarPath).path);
      return true;
    } catch (_) {
      final tmp = files.file(tmpPath);
      final tmpExists = tmp.existsSync();
      if (tmpExists) tmp.deleteSync();
      rethrow;
    }
  }
}
