/// Pure-Dart extractor for `Xcode.xip` — Apple's Xcode installer archive: a
/// XAR container holding a pbzx-framed, xz-compressed `Content` entry that
/// decompresses to an odc-cpio archive of the actual SDK files.
///
/// **Not validated against a real `Xcode.xip`** — only hand-built synthetic
/// fixtures matching the documented wire formats.
library;

import 'dart:io';

import 'package:darwin_sdk_kit/src/cpio_reader.dart';
import 'package:darwin_sdk_kit/src/errors.dart';
import 'package:darwin_sdk_kit/src/pbzx_reader.dart';
import 'package:darwin_sdk_kit/src/xar_reader.dart';

/// Streams the decoded `Content` entry of an Xcode `.xip` as [CpioEntry]s.
abstract final class XcodeXipExtractor {
  /// Decodes the format layers of [xipPath] only — filtering entries, writing
  /// them to disk, etc. is the caller's job (a follow-up `xcode_xip install`
  /// CLI command and wiring into `DarwinSdk` resolution, not this function).
  static Stream<CpioEntry> extract(String xipPath) async* {
    final file = await File(xipPath).open();
    try {
      final entry = await XarReader.findEntry(file, 'Content');
      if (entry == null) {
        throw DarwinSdkError(
          '$xipPath: no "Content" entry in the XAR table of contents.',
        );
      }
      final pbzxStream = PbzxReader.decode(
        file,
        offset: entry.offset,
        length: entry.length,
      );
      yield* CpioReader.read(pbzxStream);
    } finally {
      await file.close();
    }
  }
}
