import 'dart:ffi';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/update/checksums.dart';
import 'package:xcross/src/update/install_layout.dart';
import 'package:xcross/src/update/internal/file_swap.dart';
import 'package:xcross/src/update/internal/release_payload.dart';
import 'package:xcross/src/update/release_lookup.dart';
import 'package:xcross/src/update/semver.dart';
import 'package:xcross/src/update/update_check.dart';
import 'package:xcross/src/update/update_progress.dart';

/// Downloads a release archive and swaps it over the running installation.
abstract final class SelfUpdate {
  /// Name of the release asset for the host platform.
  ///
  /// Throws [XcrossError] on platforms that have no prebuilt release.
  static String assetName() {
    final arch = _hostArchitecture();
    if (Platform.isLinux) {
      return switch (arch) {
        'x64' => 'xcross-linux-x64.tar.gz',
        'arm64' => 'xcross-linux-arm64.tar.gz',
        _ => throw XcrossError(_unsupported(arch)),
      };
    }
    if (Platform.isWindows && arch == 'x64') return 'xcross-windows-x64.zip';
    throw XcrossError(_unsupported(arch));
  }

  static String _unsupported(String arch) =>
      'no prebuilt xcross release for ${Platform.operatingSystem}/$arch; '
      'build from source instead';

  /// The ABI name is `<os>_<arch>`, which is the only architecture answer
  /// that reflects the running binary rather than the host kernel.
  static String _hostArchitecture() {
    final abi = Abi.current().toString();
    final separator = abi.indexOf('_');
    return separator < 0 ? abi : abi.substring(separator + 1);
  }

  /// Name of the checksum manifest published alongside every release asset.
  static const checksumAsset = 'SHA256SUMS.txt';

  /// Marks the child process used to verify a newly installed binary.
  static const verificationEnvVar = 'XCROSS_SELF_UPDATE_VERIFY';

  static bool isVerificationProcess([Map<String, String>? environment]) =>
      (environment ?? Platform.environment).containsKey(verificationEnvVar);

  /// Replaces [layout] with release [tag].
  ///
  /// Downloads the asset and its checksum manifest, refuses to continue unless
  /// they agree, extracts into a scratch directory, then swaps every file into
  /// place. Any failure after the first swap rolls the whole set back.
  static Future<void> apply({
    required InstallLayout layout,
    required String tag,
  }) async {
    // The tag is interpolated into the download URL, so a value carrying path
    // segments would fetch the archive *and* its checksums from somewhere
    // else entirely, leaving verification to compare an attacker's file with
    // that same attacker's manifest.
    final version = XcrossSemver.tryParse(tag);
    if (version == null) {
      throw XcrossError('refusing to install from a non-release tag: "$tag"');
    }
    final asset = assetName();
    final progress = UpdateProgress('Release', UpdatePhases.release.length);
    final staging = await Directory.systemTemp.createTemp('xcross-update-');
    try {
      final archiveFile = File(p.join(staging.path, asset));
      await Downloader.downloadToFile(
        '${xcrossAssetBaseUrl(tag)}/$asset',
        archiveFile,
        label: progress.nextLabel('Download release archive'),
      );

      final sums = File(p.join(staging.path, checksumAsset));
      await Downloader.downloadToFile(
        '${xcrossAssetBaseUrl(tag)}/$checksumAsset',
        sums,
        label: progress.nextLabel('Download checksum manifest'),
      );

      final bytes = await archiveFile.readAsBytes();
      await progress.run('Verify archive', () async {
        Checksums.verify(
          name: asset,
          bytes: bytes,
          contents: await sums.readAsString(),
        );
      });

      final payload = Directory(p.join(staging.path, 'payload'));
      await progress.run(
        'Extract release bundle',
        () => ReleasePayload.extract(
          bytes: bytes,
          asset: asset,
          destination: payload,
          executableName: _executableName,
        ),
      );
      await installBundle(
        bundleRoot: payload,
        layout: layout,
        label: 'xcross $tag',
        expectedIdentity: version.toString(),
        expectedReleased: true,
        progress: progress,
      );
    } finally {
      await _bestEffortDelete(staging);
    }
  }

  static String get _executableName =>
      Platform.isWindows ? 'xcross.exe' : 'xcross';

  static String get _xcrunName => Platform.isWindows ? 'xcrun.exe' : 'xcrun';

  // ------------------------------------------------------------------ swap

  static Future<void> installBundle({
    required Directory bundleRoot,
    required InstallLayout layout,
    required String label,
    String? expectedIdentity,
    bool expectedReleased = false,
    UpdateProgress? progress,
    Future<CapturedProcess> Function({
      required String executable,
      required List<String> arguments,
      required Map<String, String> environment,
      required Duration timeout,
    })?
    runProcess,
  }) async {
    // Windows has no sudo to fall back on: elevation there means the user
    // relaunching in an Administrator terminal, which _requestElevation asks
    // for and this process cannot do for them.
    final useSudo = !Platform.isWindows && !layout.isWritable;
    if (!layout.isWritable) await _requestElevation(layout);

    final swap = FileSwap(useSudo: useSudo);
    try {
      final installLabel =
          progress?.nextLabel('Install $label') ?? 'Installing $label';
      await Log.logStep(installLabel, () async {
        await swap.replace(
          source: p.join(bundleRoot.path, 'bin', _executableName),
          target: p.join(layout.binDir, p.basename(layout.binaryPath)),
        );
        await swap.replace(
          source: p.join(bundleRoot.path, 'bin', _xcrunName),
          target: p.join(layout.binDir, _xcrunName),
        );
        final libs = Directory(
          p.join(bundleRoot.path, 'lib'),
        ).listSync().whereType<File>();
        for (final lib in libs) {
          await swap.replace(
            source: lib.path,
            target: p.join(layout.libDir, p.basename(lib.path)),
          );
        }
      });
      await verifyInstalledBinary(
        layout: layout,
        label: label,
        expectedIdentity: expectedIdentity,
        expectedReleased: expectedReleased,
        progress: progress,
        runProcess: runProcess,
      );
    } on Object {
      await swap.rollback();
      rethrow;
    }
    await swap.discardBackups();
  }

  /// Best-effort removal of backups a previous update could not delete.
  static void sweepStaleBackups(InstallLayout layout) =>
      FileSwap.sweepStaleBackups([layout.binDir, layout.libDir]);

  // ------------------------------------------------------------ privileges

  static Future<void> _requestElevation(InstallLayout layout) async {
    if (Platform.isWindows) {
      await HostPrivileges.ensureDeviceToolAccess(
        windowsDeniedMessage:
            'Updating xcross in ${layout.binDir} requires Administrator.\n'
            'Open PowerShell with "Run as administrator" and retry.',
      );
      return;
    }
    Log.logInfo('${layout.binDir} is not writable; elevating');
    await Sudo.cacheCredentials(manualHint: 'Retry with: sudo xcross update');
  }

  static Future<void> _bestEffortDelete(Directory directory) async {
    try {
      await directory.delete(recursive: true);
    } on FileSystemException {
      // A leftover scratch directory is not worth failing the update for.
    }
  }

  // --------------------------------------------------------- verification

  /// Runs the freshly installed binary, which is also the only check that the
  /// native libraries next to it still load.
  ///
  /// The child must not run the update check: it would sweep the very backups
  /// this run still needs for a rollback, and reach the network for nothing.
  static Future<CapturedProcess> verifyInstalledBinary({
    required InstallLayout layout,
    required String label,
    String? expectedIdentity,
    bool expectedReleased = false,
    UpdateProgress? progress,
    Future<CapturedProcess> Function({
      required String executable,
      required List<String> arguments,
      required Map<String, String> environment,
      required Duration timeout,
    })?
    runProcess,
  }) async {
    final verifyLabel =
        progress?.nextLabel('Verify $label') ?? 'Verifying $label';
    final result = await Log.logStep(
      verifyLabel,
      () => _runVersionCheck(layout, runProcess: runProcess),
    );
    // Scanned rather than parsed positionally: the credits banner also starts
    // with the word "xcross", and a false negative here would roll back a
    // perfectly good update.
    final reported = result.stdout
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.startsWith('xcross '));
    if (result.exitCode != 0) {
      throw XcrossError(
        'the installed binary did not report xcross identity for '
        '$label (exit ${result.exitCode}); restoring the previous version',
      );
    }
    if (expectedIdentity != null) {
      final releasedIdentity = expectedReleased
          ? XcrossSemver.tryParse(expectedIdentity)?.toString()
          : null;
      final expected = expectedReleased
          ? 'xcross ${releasedIdentity ?? expectedIdentity}'
          : 'xcross $expectedIdentity (unreleased build)';
      if (!reported.contains(expected)) {
        throw XcrossError(
          'the installed binary did not report $expected '
          '(exit ${result.exitCode}); restoring the previous version',
        );
      }
      return result;
    }
    if (reported.isEmpty) {
      throw XcrossError(
        'the installed binary did not report xcross identity for '
        '$label (exit ${result.exitCode}); restoring the previous version',
      );
    }
    return result;
  }

  static Future<CapturedProcess> _runVersionCheck(
    InstallLayout layout, {
    Future<CapturedProcess> Function({
      required String executable,
      required List<String> arguments,
      required Map<String, String> environment,
      required Duration timeout,
    })?
    runProcess,
  }) => (runProcess ?? _defaultRunProcess)(
    executable: layout.binaryPath,
    arguments: const ['--version'],
    environment: {UpdateCheck.disableEnvVar: '1', verificationEnvVar: '1'},
    timeout: const Duration(seconds: 30),
  );

  static Future<CapturedProcess> _defaultRunProcess({
    required String executable,
    required List<String> arguments,
    required Map<String, String> environment,
    required Duration timeout,
  }) => ProcessRunner.run(
    executable,
    arguments,
    environment: environment,
  ).timeout(timeout);
}
