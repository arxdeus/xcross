import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/progress/progress.dart';
import 'package:darwin_sdk_kit/shared/archive/xcode_xip_extractor.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk_repository.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/cli/basic/internal/swift_requirement.dart';
import 'package:xcross/src/shared/cli/basic/sdk_install.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/sdk/xcode_swift_requirement.dart';

/// `xcross sdk` — manage xcross's host-neutral Darwin Swift SDK.
@internal
final class SdkCommand<T extends PlatformHostInterface> extends Command<void> {
  SdkCommand(SdkInstall<T> installer) {
    addSubcommand(SdkInstallCommand(installer));
  }

  @override
  String get name => 'sdk';

  @override
  String get description => 'Manage the xcross Darwin Swift SDK.';
}

/// `xcross sdk install <Xcode.xip>` — build xcross's Darwin Swift SDK bundle.
@internal
final class SdkInstallCommand<T extends PlatformHostInterface>
    extends Command<void> {
  SdkInstallCommand(this.installer);
  final SdkInstall<T> installer;
  T get host => installer.host;
  Log get log => installer.log;
  p.Context get _paths => host.paths.context;
  @override
  String get name => 'install';

  @override
  String get description =>
      'Extract a host-neutral Darwin Swift SDK from an Xcode.xip or Xcode.app.';

  @override
  String get invocation => 'xcross sdk install <path-to-Xcode.xip|Xcode.app>';

  @override
  Future<void> run() async {
    final sourcePath = argResults!.rest.firstOrNull;
    if (sourcePath == null) throw XcrossError('Usage: $invocation');
    final isXcodeApp = host.fileSystem.directory(sourcePath).existsSync();
    if (!isXcodeApp && !host.fileSystem.file(sourcePath).existsSync()) {
      throw XcrossError('No file found at "$sourcePath".');
    }
    if (isXcodeApp &&
        !host.fileSystem
            .directory(_paths.join(sourcePath, 'Contents', 'Developer'))
            .existsSync()) {
      throw XcrossError('No Xcode Developer directory found in "$sourcePath".');
    }

    // Checked before the archive is touched: extraction takes a long while
    // and tens of gigabytes, and its whole point is to produce a bundle
    // patched against — and stamped with — the selected Swift toolchain. With
    // no Swift on PATH that work is wasted, and the old failure came only
    // after the extraction had already finished.
    final swift = await SwiftRequirement(installer.runner).require(
      'install the Darwin SDK',
      installGuidance: installer.swiftInstallGuidance,
    );
    await SwiftRequirement(installer.runner).requireSiblingClang(swift);

    // Newer Xcode SDKs cannot be consumed by older Swift compilers at all, so
    // the pairing is rejected here rather than after the extraction. The
    // archive's file name is only a hint (downloads get renamed), but when it
    // does name a generation this costs the user nothing to learn early; the
    // extracted SDK is checked again below, where the answer is authoritative.
    await _requireSwiftForXcode(
      XcodeSwiftRequirement.xcodeMajorFromXipPath(sourcePath),
      swift,
    );

    // Check the archive before allocating space for a second SDK copy.
    if (!isXcodeApp) {
      await log.logStep(
        'Verifying archive',
        () => XcodeXipExtractor(host).validate(sourcePath),
      );
    }

    final destDir = installer.repository.installBundle;
    await prepareExistingSdk(destDir);
    final staged = await createStagingSibling(destDir);
    try {
      final written = await _extract(
        sourcePath,
        staged.path,
        isXcodeApp: isXcodeApp,
      );
      if (written == 0) {
        throw XcrossError(
          '$sourcePath: extraction produced no files from the required iOS SDK '
          'subset. Verify that this is a complete Xcode installation.',
        );
      }
      await _completeStagedSdk(staged.path);
      // A renamed archive can bypass the filename preflight. Verify the
      // actual SDK before replacing the user's working installation.
      await _requireSwiftForXcode(
        XcodeSwiftRequirement.xcodeMajorFromSdkPath(
          installer.repository.iosSdk(
            DarwinSdk(staged.path),
            target: installer.metadataPlatforms.first.buildPlatform,
          ),
        ),
        swift,
      );
      requireValidStagedSdk(staged.path);
      await activateStagedSdk(staged, destDir);
      log.logDone(
        'Installed Darwin Swift SDK '
        '(${ProgressBar.formatCount(written)} entries) at $destDir',
      );
    } finally {
      if (staged.existsSync()) {
        await _deleteSdkDirectoryOrWarn(staged.path, 'staged SDK');
      }
    }
  }

  /// Extract next to [destDir] so publishing is a same-volume rename.
  Future<Directory> createStagingSibling(String destDir) async {
    final parent = host.fileSystem.directory(_paths.dirname(destDir));
    await parent.create(recursive: true);
    return parent.createTemp('${_paths.basename(destDir)}.staging-');
  }

  /// Post-extraction fixups that turn raw Xcode files into a Swift SDK bundle.
  Future<void> _completeStagedSdk(String stagedPath) async {
    await log.logStep(
      'Patching clang builtin headers',
      () => installer.replaceClangBuiltinHeaders(stagedPath),
    );
    await log.logStep(
      'Copying Swift compatibility resources',
      () => installer.materializeSwiftCompatibilityResources(stagedPath),
    );
    await log.logStep(
      'Writing Swift SDK metadata',
      () => installer.writeSwiftSdkBundleMetadata(stagedPath),
    );
  }

  Future<void> _deleteSdkDirectory(String path) =>
      host.fileSystem.directory(installer.ioPath(path)).delete(recursive: true);

  /// Best-effort cleanup: a leftover directory must not fail the install.
  Future<void> _deleteSdkDirectoryOrWarn(
    String path,
    String description,
  ) async {
    try {
      await _deleteSdkDirectory(path);
    } on Object catch (error) {
      log.logWarn('Could not remove $description at $path: $error');
    }
  }

  /// Do not replace a usable install with an archive missing required SDK
  /// frameworks or Swift runtime files.
  void requireValidStagedSdk(String stagedPath) {
    if (!installer.repository.isValidBundle(stagedPath)) {
      throw XcrossError(
        'The extracted Xcode archive produced an incomplete Darwin Swift '
        'SDK. The previous SDK remains installed.',
      );
    }
  }

  /// Recover an interrupted swap and clear a leftover backup only when the
  /// published SDK is known to be usable.
  Future<void> prepareExistingSdk(String destDir) async {
    installer.repository.restoreInterruptedInstall(destDir);
    final backup = host.fileSystem.directory(
      DarwinSdkRepository.previousInstallPath(destDir),
    );
    if (!backup.existsSync()) return;
    if (!installer.repository.isValidBundle(destDir)) {
      throw XcrossError(
        'The installed Darwin Swift SDK is incomplete. The previous SDK is '
        'preserved at ${backup.path}; restore it before installing again.',
      );
    }
    await log.logStep(
      'Removing previous SDK backup',
      () => _deleteSdkDirectory(backup.path),
    );
  }

  /// Swap a validated sibling into place, restoring the old SDK if the new
  /// directory cannot be published.
  Future<void> activateStagedSdk(
    Directory staged,
    String destDir, {
    Future<Directory> Function(Directory, String)? renameStaged,
  }) async {
    if (host.paths.pathKey(host.paths.ioPath(_paths.dirname(staged.path))) !=
        host.paths.pathKey(host.paths.ioPath(_paths.dirname(destDir)))) {
      throw ArgumentError(
        'The staged SDK must be a sibling of the destination',
      );
    }
    final previous = host.fileSystem.directory(installer.ioPath(destDir));
    final backup = host.fileSystem.directory(
      DarwinSdkRepository.previousInstallPath(destDir),
    );
    if (backup.existsSync()) {
      throw StateError('SDK backup path already exists: ${backup.path}');
    }
    final hadPrevious = previous.existsSync();
    if (hadPrevious) await previous.rename(backup.path);
    final publish = renameStaged ?? (directory, path) => directory.rename(path);
    try {
      await publish(staged, destDir);
    } on Object {
      if (hadPrevious) await backup.rename(destDir);
      rethrow;
    }
    if (hadPrevious) {
      await _deleteSdkDirectoryOrWarn(backup.path, 'old SDK');
    }
  }

  /// Throws [XcrossError] when the host Swift is older than an Xcode
  /// [xcodeMajor] SDK requires. A null [xcodeMajor], or a toolchain that
  /// reports no version, is not an error: see [XcodeSwiftRequirement].
  Future<void> _requireSwiftForXcode(int? xcodeMajor, String swift) async {
    if (xcodeMajor == null) return;
    if (XcodeSwiftRequirement.minimumSwift(xcodeMajor) == null) return;
    final String version;
    try {
      version = (await installer.hostToolchainIdentity())['version'] ?? '';
    } on Object catch (error) {
      log.logTrace('Could not read the host Swift version: $error');
      return;
    }
    final problem = XcodeSwiftRequirement.mismatchWithHint(
      xcodeMajor: xcodeMajor,
      swiftVersionOutput: version,
      swiftPath: swift,
      installHint: installer.swiftInstallGuidance,
    );
    if (problem != null) throw XcrossError(problem);
  }

  /// Percentages track the compressed `Content` stream, the only size the
  /// archive declares up front; the entry and symlink counts ride along as the
  /// bar's trailing note so a stalled phase is still visibly doing work.
  Future<int> _extract(
    String sourcePath,
    String destDir, {
    bool isXcodeApp = false,
  }) async {
    final bar = ProgressBar('Extracting Darwin SDK', log: log);
    try {
      final written = await installer.writeSdkEntries(
        isXcodeApp
            ? installer.xcodeAppEntries(sourcePath)
            : XcodeXipExtractor(host).extract(
                sourcePath,
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
