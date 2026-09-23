import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/cli/basic/internal/swift_requirement.dart';
import 'package:xcross/src/cli/basic/internal/xcode_swift_requirement.dart';
import 'package:xcross/src/cli/basic/sdk_install.dart';
import 'package:xcross/src/errors.dart';

export 'package:xcross/src/cli/basic/sdk_install.dart';

/// `xcross sdk` — manage xcross's host-neutral Darwin Swift SDK.
final class SdkCommand extends Command<void> {
  SdkCommand() {
    addSubcommand(SdkInstallCommand());
  }

  @override
  String get name => 'sdk';

  @override
  String get description => 'Manage the xcross Darwin Swift SDK.';
}

/// `xcross sdk install <Xcode.xip>` — build xcross's Darwin Swift SDK bundle.
final class SdkInstallCommand extends Command<void> {
  @override
  String get name => 'install';

  @override
  String get description =>
      'Extract a host-neutral Darwin Swift SDK from an Xcode.xip.';

  @override
  String get invocation => 'xcross sdk install <path-to-Xcode.xip>';

  @override
  Future<void> run() async {
    final xipPath = argResults!.rest.firstOrNull;
    if (xipPath == null) throw XcrossError('Usage: $invocation');
    if (!File(xipPath).existsSync()) {
      throw XcrossError('No file found at "$xipPath".');
    }

    // Checked before the archive is touched: extraction takes a long while
    // and tens of gigabytes, and its whole point is to produce a bundle
    // patched against — and stamped with — the selected Swift toolchain. With
    // no Swift on PATH that work is wasted, and the old failure came only
    // after the extraction had already finished.
    final swift = await SwiftRequirement.require('install the Darwin SDK');
    await SwiftRequirement.requireSiblingClang(swift);

    // Newer Xcode SDKs cannot be consumed by older Swift compilers at all, so
    // the pairing is rejected here rather than after the extraction. The
    // archive's file name is only a hint (downloads get renamed), but when it
    // does name a generation this costs the user nothing to learn early; the
    // extracted SDK is checked again below, where the answer is authoritative.
    await _requireSwiftForXcode(
      XcodeSwiftRequirement.xcodeMajorFromXipPath(xipPath),
      swift,
    );

    // Check the archive before allocating space for a second SDK copy.
    await Log.logStep(
      'Verifying archive',
      () => XcodeXipExtractor.validate(xipPath),
    );

    final destDir = DarwinSdk.nativeInstallDir();
    await prepareExistingSdk(destDir);
    final parent = Directory(p.dirname(destDir));
    await parent.create(recursive: true);
    final staged = await parent.createTemp('${p.basename(destDir)}.staging-');
    try {
      final written = await _extract(xipPath, staged.path);
      if (written == 0) {
        throw XcrossError(
          '$xipPath: extraction produced no files from the required iOS SDK '
          'subset. Verify that this is a complete Xcode.xip.',
        );
      }

      await Log.logStep(
        'Patching clang builtin headers',
        () => SdkInstall.replaceClangBuiltinHeaders(staged.path),
      );
      await Log.logStep(
        'Copying Swift compatibility resources',
        () => SdkInstall.materializeSwiftCompatibilityResources(staged.path),
      );
      await Log.logStep(
        'Writing Swift SDK metadata',
        () => SdkInstall.writeSwiftSdkBundleMetadata(staged.path),
      );
      // A renamed archive can bypass the filename preflight. Verify the
      // actual SDK before replacing the user's working installation.
      await _requireSwiftForXcode(
        XcodeSwiftRequirement.xcodeMajorFromSdkPath(
          DarwinSdk(staged.path).iPhoneOSSdk(),
        ),
        swift,
      );
      requireValidStagedSdk(staged.path);
      await activateStagedSdk(staged, destDir);
      Log.logDone(
        'Installed Darwin Swift SDK '
        '(${ProgressBar.formatCount(written)} entries) at $destDir',
      );
    } finally {
      if (staged.existsSync()) {
        try {
          await Directory(
            SdkInstall.ioPath(staged.path),
          ).delete(recursive: true);
        } on Object catch (error) {
          Log.logWarn('Could not remove staged SDK at ${staged.path}: $error');
        }
      }
    }
  }

  /// Do not replace a usable install with an archive missing required SDK
  /// frameworks or Swift runtime files.
  static void requireValidStagedSdk(String stagedPath) {
    if (!DarwinSdk.isValidBundle(stagedPath)) {
      throw XcrossError(
        'The extracted Xcode archive produced an incomplete Darwin Swift '
        'SDK. The previous SDK remains installed.',
      );
    }
  }

  /// Recover an interrupted swap and clear a leftover backup only when the
  /// published SDK is known to be usable.
  static Future<void> prepareExistingSdk(String destDir) async {
    DarwinSdk.restoreInterruptedInstall(destDir);
    final backup = Directory('$destDir.previous');
    if (!backup.existsSync()) return;
    if (!DarwinSdk.isValidBundle(destDir)) {
      throw XcrossError(
        'The installed Darwin Swift SDK is incomplete. The previous SDK is '
        'preserved at ${backup.path}; restore it before installing again.',
      );
    }
    await Log.logStep(
      'Removing previous SDK backup',
      () => Directory(SdkInstall.ioPath(backup.path)).delete(recursive: true),
    );
  }

  /// Swap a validated sibling into place, restoring the old SDK if the new
  /// directory cannot be published.
  static Future<void> activateStagedSdk(
    Directory staged,
    String destDir, {
    Future<Directory> Function(Directory, String)? renameStaged,
  }) async {
    if (p.dirname(p.normalize(staged.path)) !=
        p.dirname(p.normalize(destDir))) {
      throw ArgumentError(
        'The staged SDK must be a sibling of the destination',
      );
    }
    final previous = Directory(SdkInstall.ioPath(destDir));
    final backup = Directory('$destDir.previous');
    if (backup.existsSync()) {
      throw StateError('SDK backup path already exists: ${backup.path}');
    }
    final hadPrevious = previous.existsSync();
    if (hadPrevious) await previous.rename(backup.path);
    try {
      await (renameStaged ?? (directory, path) => directory.rename(path))(
        staged,
        destDir,
      );
    } on Object {
      if (hadPrevious) await backup.rename(destDir);
      rethrow;
    }
    if (hadPrevious) {
      try {
        await Directory(SdkInstall.ioPath(backup.path)).delete(recursive: true);
      } on Object catch (error) {
        Log.logWarn('Could not remove old SDK at ${backup.path}: $error');
      }
    }
  }

  /// Throws [XcrossError] when the host Swift is older than an Xcode
  /// [xcodeMajor] SDK requires. A null [xcodeMajor], or a toolchain that
  /// reports no version, is not an error: see [XcodeSwiftRequirement].
  static Future<void> _requireSwiftForXcode(
    int? xcodeMajor,
    String swift,
  ) async {
    if (xcodeMajor == null) return;
    if (XcodeSwiftRequirement.minimumSwift(xcodeMajor) == null) return;
    final String version;
    try {
      version = (await SdkInstall.hostToolchainIdentity())['version'] ?? '';
    } on Object catch (error) {
      Log.logTrace('Could not read the host Swift version: $error');
      return;
    }
    final problem = XcodeSwiftRequirement.mismatchWithHint(
      xcodeMajor: xcodeMajor,
      swiftVersionOutput: version,
      swiftPath: swift,
      installHint: SwiftRequirement.installHint(),
    );
    if (problem != null) throw XcrossError(problem);
  }

  /// Percentages track the compressed `Content` stream, the only size the
  /// archive declares up front; the entry and symlink counts ride along as the
  /// bar's trailing note so a stalled phase is still visibly doing work.
  Future<int> _extract(String xipPath, String destDir) async {
    final bar = ProgressBar('Extracting Darwin SDK');
    try {
      final written = await SdkInstall.writeSdkEntries(
        XcodeXipExtractor.extract(
          xipPath,
          onProgress: (consumed, total) {
            bar.total = total;
            bar.update(consumed);
          },
        ),
        destDir,
        onProgress: (count) =>
            bar.note = '${ProgressBar.formatCount(count)} entries',
        onLinkProgress: (done, total) => bar.note = 'linking $done/$total',
      );
      bar.finish('${ProgressBar.formatCount(written)} entries');
      return written;
    } on Object {
      bar.fail();
      rethrow;
    }
  }
}
