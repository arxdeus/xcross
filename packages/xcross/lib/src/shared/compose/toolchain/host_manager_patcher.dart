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

Uint8List? _patchedEntryBytes(ArchiveFile entry) {
  final name = entry.name;
  if (name == hostManagerClassEntry) {
    return patchHostManagerClassBytes(entry.readBytes()!);
  }
  if (name == objcExportClassEntry) {
    return patchObjCExportClassBytes(entry.readBytes()!);
  }
  if (name == appleConfigurablesImplClassEntry) {
    return patchAppleConfigurablesImplClassBytes(entry.readBytes()!);
  }
  return null;
}

bool _addPatchedOrUnmodifiedEntry(ZipEncoder encoder, ArchiveFile entry) {
  final patched = _patchedEntryBytes(entry);
  if (patched == null) {
    _addUnmodifiedEntry(encoder, entry);
    return false;
  }
  encoder.add(ArchiveFile(entry.name, patched.length, patched));
  return true;
}

void _rejectDuplicateArchiveEntries(Archive archive) {
  final names = <String>{};
  for (final entry in archive.files) {
    if (!names.add(entry.name)) {
      throw StateError('HostManagerPatcher: duplicate JAR entry ${entry.name}');
    }
  }
}

bool _hasPatchableEntry(Archive archive) {
  bool contains(String entryName) =>
      archive.files.any((f) => f.name == entryName);
  final hasHm = contains(hostManagerClassEntry);
  final hasObjC = contains(objcExportClassEntry);
  final hasAcfg = contains(appleConfigurablesImplClassEntry);
  return hasHm || hasObjC || hasAcfg;
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
      _rejectDuplicateArchiveEntries(archive);

      // Check idempotency marker.
      final alreadyPatched = archive.files.any((f) => f.name == jarMarkerPath);
      if (alreadyPatched) {
        return false;
      }
      if (!_hasPatchableEntry(archive)) {
        return false;
      }

      final didPatch = _writePatchedArchive(archive, tmpPath);
      if (!didPatch) return false;

      // Atomic replace.
      files.file(tmpPath).renameSync(files.file(jarPath).path);
      return true;
    } catch (_) {
      _deleteTempIfPresent(tmpPath);
      rethrow;
    }
  }

  bool _writePatchedArchive(Archive archive, String tmpPath) {
    // Rebuild the archive with patched entries, streaming to a temp file.
    final output = OutputFileStream(files.file(tmpPath).path);
    final encoder = ZipEncoder();
    encoder.startEncode(output);
    var didPatch = false;

    try {
      for (final entry in archive.files) {
        if (_addPatchedOrUnmodifiedEntry(encoder, entry)) didPatch = true;
      }

      if (!didPatch) {
        encoder.endEncode();
        output.closeSync();
        _deleteTempIfPresent(tmpPath);
        return false;
      }

      // Write idempotency marker.
      final markerBytes = utf8.encode('patched\n');
      encoder.add(ArchiveFile(jarMarkerPath, markerBytes.length, markerBytes));
      encoder.endEncode();
    } on Object catch (_) {
      try {
        output.closeSync();
      } on Object catch (_) {}
      _deleteTempIfPresent(tmpPath);
      rethrow;
    }

    output.closeSync();
    return true;
  }

  void _deleteTempIfPresent(String tmpPath) {
    final tmp = files.file(tmpPath);
    final tmpExists = tmp.existsSync();
    if (tmpExists) tmp.deleteSync();
  }
}
