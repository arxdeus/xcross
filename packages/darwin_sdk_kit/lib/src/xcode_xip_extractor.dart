/// Pure-Dart extractor for `Xcode.xip` — Apple's Xcode installer archive.
///
/// The format nests three layers, decoded here by `xar_reader.dart`,
/// `pbzx_reader.dart`, and `cpio_reader.dart` respectively: a XAR container
/// holding a `Content` entry, which is pbzx-framed and xz-compressed, which
/// in turn decompresses to a classic odc-cpio archive holding the actual SDK
/// files.
///
/// **This has NOT been validated against a real `Xcode.xip`.** It was
/// written and tested entirely against hand-built synthetic fixtures (see
/// `test/darwinsdk/`) matching the documented wire formats, cross-checked
/// against the XAR spec header (`mackyle/xar`), `saagarjha/unxip`'s Swift
/// pbzx/cpio implementation, and `NiklasRosenstein/pbzx`'s C source —
/// because a real Xcode.xip is a multi-gigabyte, Apple-account-gated
/// download unavailable in the environment this was written in. Run this
/// against a real Xcode.xip and confirm it extracts a plausible SDK tree
/// before trusting it for an actual SDK install.
library;

import 'dart:io';

import 'package:darwin_sdk_kit/src/cpio_reader.dart';
import 'package:darwin_sdk_kit/src/errors.dart';
import 'package:darwin_sdk_kit/src/pbzx_reader.dart';
import 'package:darwin_sdk_kit/src/xar_reader.dart';

/// Streams the decoded `Content` entry of an Xcode `.xip` as [CpioEntry]s.
abstract final class XcodeXipExtractor {
  /// Streams the decoded `Content` entry of [xipPath] as a sequence of
  /// [CpioEntry]s.
  ///
  /// This only decodes the format layers — filtering entries, writing them to
  /// disk, etc. is the caller's job (a follow-up `xcode_xip install` CLI
  /// command and wiring into `DarwinSdk` resolution, not this function).
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
