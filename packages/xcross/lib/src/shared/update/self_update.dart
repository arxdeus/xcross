import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/update/checksums.dart';
import 'package:xcross/src/shared/update/install_layout.dart';
import 'package:xcross/src/shared/update/internal/file_swap.dart';
import 'package:xcross/src/shared/update/internal/release_payload.dart';
import 'package:xcross/src/shared/update/release_lookup.dart';
import 'package:xcross/src/shared/update/semver.dart';
import 'package:xcross/src/shared/update/update_check.dart';
import 'package:xcross/src/shared/update/update_host_policy.dart';
import 'package:xcross/src/shared/update/update_progress.dart';

typedef UpdateVerificationProcess =
    Future<CapturedProcess> Function({
      required String executable,
      required List<String> arguments,
      required Map<String, String> environment,
      required Duration timeout,
    });

/// Downloads a release archive and swaps it over the running installation.
final class SelfUpdate {
  SelfUpdate({
    required this.host,
    required this.runner,
    required this.policy,
    required this.downloader,
    UpdateVerificationProcess? verifyProcess,
  }) : _backupCleaner = StaleBackupCleaner(
         fileSystem: host.fileSystem,
         paths: host.paths.context,
       ),
       _verifyProcess =
           verifyProcess ??
           (({
             required executable,
             required arguments,
             required environment,
             required timeout,
           }) => runner
               .run(executable, arguments, environment: environment)
               .timeout(timeout));
  final PlatformHostInterface host;
  final ProcessRunner runner;
  final UpdateHostPolicy policy;
  final Downloader downloader;
  final UpdateVerificationProcess _verifyProcess;
  final StaleBackupCleaner _backupCleaner;

  String assetName() => policy.releaseAsset();

  /// Name of the checksum manifest published alongside every release asset.
  static const checksumAsset = 'SHA256SUMS.txt';

  /// Marks the child process used to verify a newly installed binary.
  static const verificationEnvVar = 'XCROSS_SELF_UPDATE_VERIFY';

  static bool isVerificationProcess(Map<String, String> environment) =>
      environment.containsKey(verificationEnvVar);

  /// Replaces [layout] with release [tag].
  ///
  /// Downloads the asset and its checksum manifest, refuses to continue unless
  /// they agree, extracts into a scratch directory, then swaps every file into
  /// place. Any failure after the first swap rolls the whole set back.
  Future<void> apply({
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
    final progress = UpdateProgress(
      'Release',
      UpdatePhases.release.length,
      log: runner.log,
    );
    final staging = await host.fileSystem
        .directory(host.paths.temporaryRoot)
        .createTemp('xcross-update-');
    final stagingPath = host.paths.context.join(
      host.paths.temporaryRoot,
      host.paths.context.basename(staging.path),
    );
    try {
      final archiveFile = host.fileSystem.file(
        host.paths.context.join(stagingPath, asset),
      );
      await downloader.downloadToFile(
        '${xcrossAssetBaseUrl(tag)}/$asset',
        archiveFile,
        label: progress.nextLabel('Download release archive'),
      );

      final sums = host.fileSystem.file(
        host.paths.context.join(stagingPath, checksumAsset),
      );
      await downloader.downloadToFile(
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

      final payloadPath = host.paths.context.join(stagingPath, 'payload');
      final payload = host.fileSystem.directory(payloadPath);
      await progress.run(
        'Extract release bundle',
        () => ReleasePayload(host).extract(
          bytes: bytes,
          asset: asset,
          destination: payloadPath,
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

  String get _executableName => host.paths.executableName('xcross');
  String get _xcrunName => host.paths.executableName('xcrun');

  // ------------------------------------------------------------------ swap

  Future<void> installBundle({
    required Directory bundleRoot,
    required InstallLayout layout,
    required String label,
    String? expectedIdentity,
    bool expectedReleased = false,
    UpdateProgress? progress,
  }) async {
    final swap = FileSwap(
      operations: await policy.prepare(layout),
      log: runner.log,
    );
    try {
      final installLabel =
          progress?.nextLabel('Install $label') ?? 'Installing $label';
      await runner.log.logStep(installLabel, () async {
        await swap.replace(
          source: host.paths.context.join(
            bundleRoot.path,
            'bin',
            _executableName,
          ),
          target: host.paths.context.join(
            layout.binDir,
            host.paths.context.basename(layout.binaryPath),
          ),
        );
        await swap.replace(
          source: host.paths.context.join(bundleRoot.path, 'bin', _xcrunName),
          target: host.paths.context.join(layout.binDir, _xcrunName),
        );
        final libs = host.fileSystem
            .directory(host.paths.context.join(bundleRoot.path, 'lib'))
            .listSync()
            .whereType<File>();
        for (final lib in libs) {
          await swap.replace(
            source: lib.path,
            target: host.paths.context.join(
              layout.libDir,
              host.paths.context.basename(lib.path),
            ),
          );
        }
      });
      await verifyInstalledBinary(
        layout: layout,
        label: label,
        expectedIdentity: expectedIdentity,
        expectedReleased: expectedReleased,
        progress: progress,
      );
    } on Object {
      await swap.rollback();
      rethrow;
    }
    await swap.discardBackups();
  }

  /// Best-effort removal of backups a previous update could not delete.
  void sweepStaleBackups(InstallLayout layout) =>
      _backupCleaner.sweep([layout.binDir, layout.libDir]);

  // ------------------------------------------------------------ privileges

  Future<void> _bestEffortDelete(Directory directory) async {
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
  Future<CapturedProcess> verifyInstalledBinary({
    required InstallLayout layout,
    required String label,
    String? expectedIdentity,
    bool expectedReleased = false,
    UpdateProgress? progress,
  }) async {
    final verifyLabel =
        progress?.nextLabel('Verify $label') ?? 'Verifying $label';
    final result = await runner.log.logStep(
      verifyLabel,
      () => _runVersionCheck(layout),
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

  Future<CapturedProcess> _runVersionCheck(InstallLayout layout) =>
      _verifyProcess(
        executable: layout.binaryPath,
        arguments: const ['--version'],
        environment: {UpdateCheck.disableEnvVar: '1', verificationEnvVar: '1'},
        timeout: const Duration(seconds: 30),
      );
}
