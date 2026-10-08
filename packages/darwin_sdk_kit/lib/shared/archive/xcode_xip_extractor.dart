/// Pure-Dart extractor for `Xcode.xip` — Apple's Xcode installer archive: a
/// XAR container holding a pbzx-framed, xz-compressed `Content` entry that
/// decompresses to an odc-cpio archive of the actual SDK files.
///
/// **Not validated against a real `Xcode.xip`** — only hand-built synthetic
/// fixtures matching the documented wire formats.
library;

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:darwin_sdk_kit/shared/archive/cpio_reader.dart';
import 'package:darwin_sdk_kit/shared/errors/errors.dart';
import 'package:darwin_sdk_kit/src/shared/archive/pbzx_reader.dart';
import 'package:darwin_sdk_kit/src/shared/archive/xar_reader.dart';

/// Streams the decoded `Content` entry of an Xcode `.xip` as [CpioEntry]s.
final class XcodeXipExtractor<T extends PlatformHostInterface> {
  const XcodeXipExtractor(this.host);
  final T host;

  /// Verifies [xipPath] is a XAR archive carrying the `Content` entry an
  /// Xcode `.xip` must have, throwing [DarwinSdkError] otherwise.
  ///
  /// Reads only the header and table of contents, so it is fast enough to run
  /// before anything destructive. `sdk install` replaces a working SDK, and
  /// discovering "not a XAR file" *after* deleting it costs the user a
  /// multi-gigabyte reinstall over a typo.
  Future<void> validate(String xipPath) async {
    final file = await host.fileSystem.file(xipPath).open();
    try {
      final entry = await XarReader.findEntry(file, 'Content');
      if (entry == null) {
        throw DarwinSdkError(
          '$xipPath: no "Content" entry in the XAR table of contents.\n'
          'This does not look like a complete Xcode.xip.',
        );
      }
    } finally {
      await file.close();
    }
  }

  /// Decodes the format layers of [xipPath] only — filtering entries, writing
  /// them to disk, etc. is the caller's job (a follow-up `xcode_xip install`
  /// CLI command and wiring into `DarwinSdk` resolution, not this function).
  ///
  /// [onProgress] reports compressed bytes of the `Content` entry consumed so
  /// far against its total size — the only length known before the archive is
  /// decoded, and the one that tracks the work still to do.
  Stream<CpioEntry> extract(
    String xipPath, {
    void Function(int consumed, int total)? onProgress,
  }) async* {
    final file = await host.fileSystem.file(xipPath).open();
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
        onProgress: onProgress == null
            ? null
            : (consumed) => onProgress(consumed, entry.length),
      );
      yield* CpioReader.read(pbzxStream);
    } finally {
      await file.close();
    }
  }
}
