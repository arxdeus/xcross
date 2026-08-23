import 'dart:ffi';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/update/checksums.dart';
import 'package:xcross/src/update/install_layout.dart';
import 'package:xcross/src/update/internal/file_swap.dart';
import 'package:xcross/src/update/internal/release_payload.dart';
import 'package:xcross/src/update/release_lookup.dart';
import 'package:xcross/src/update/semver.dart';
import 'package:xcross/src/update/update_check.dart';

/// Downloads a release archive and swaps it over the running installation.
abstract final class SelfUpdate {
  @visibleForTesting
  static Future<CapturedProcess> Function({
    required String executable,
    required List<String> arguments,
    required Map<String, String> environment,
    required Duration timeout,
  }) processRunner = ({
    required String executable,
    required List<String> arguments,
    required Map<String, String> environment,
    required Duration timeout,
  }) => ProcessRunner.run(
    executable,
    arguments,
    environment: environment,
  ).timeout(timeout);

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
    if (XcrossSemver.tryParse(tag) == null) {
      throw XcrossError('refusing to install from a non-release tag: "$tag"');
    }
    final asset = assetName();
    final staging = await Directory.systemTemp.createTemp('xcross-update-');
    try {
      final archiveFile = File(p.join(staging.path, asset));
      await Downloader.downloadToFile(
        '${xcrossAssetBaseUrl(tag)}/$asset',
        archiveFile,
        label: asset,
      );

      final sums = File(p.join(staging.path, checksumAsset));
      await Downloader.downloadToFile(
        '${xcrossAssetBaseUrl(tag)}/$checksumAsset',
        sums,
        label: checksumAsset,
      );

      final bytes = await archiveFile.readAsBytes();
      await Log.logStep('Verifying $asset', () async {
        Checksums.verify(
          name: asset,
          bytes: bytes,
          contents: await sums.readAsString(),
        );
      });

      final payload = Directory(p.join(staging.path, 'payload'));
      await ReleasePayload.extract(
        bytes: bytes,
        asset: asset,
        destination: payload,
        executableName: _executableName,
      );
      await installBundle(
        bundleRoot: payload,
        layout: layout,
        label: 'xcross $tag',
        expectedVersion: XcrossSemver.tryParse(tag),
      );
    } finally {
      await _bestEffortDelete(staging);
    }
  }

  static String get _executableName =>
      Platform.isWindows ? 'xcross.exe' : 'xcross';

  // ------------------------------------------------------------------ swap

  static Future<void> installBundle({
    required Directory bundleRoot,
    required InstallLayout layout,
    required String label,
    XcrossSemver? expectedVersion,
    Future<CapturedProcess> Function({
      required InstallLayout layout,
      required XcrossSemver? expectedVersion,
    })?
    verifyInstalledBinary,
  }) async {
    // Windows has no sudo to fall back on: elevation there means the user
    // relaunching in an Administrator terminal, which _requestElevation asks
    // for and this process cannot do for them.
    final useSudo = !Platform.isWindows && !layout.isWritable;
    if (!layout.isWritable) await _requestElevation(layout);

    final swap = FileSwap(useSudo: useSudo);
    try {
      await Log.logStep('Installing $label', () async {
        await swap.replace(
          source: p.join(bundleRoot.path, 'bin', _executableName),
          target: p.join(layout.binDir, p.basename(layout.binaryPath)),
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
      await (verifyInstalledBinary ??
              ({required layout, required expectedVersion}) =>
                  SelfUpdate.verifyInstalledBinary(
                    layout: layout,
                    label: label,
                    expectedVersion: expectedVersion,
                  ))(
        layout: layout,
        expectedVersion: expectedVersion,
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
    XcrossSemver? expectedVersion,
    Future<CapturedProcess> Function({
      required String executable,
      required List<String> arguments,
      required Map<String, String> environment,
      required Duration timeout,
    })?
    runProcess,
  }) async {
    final result = await (runProcess ?? processRunner)(
      executable: layout.binaryPath,
      arguments: const ['--version'],
      environment: {UpdateCheck.disableEnvVar: '1'},
      timeout: const Duration(seconds: 30),
    );
    // Scanned rather than parsed positionally: the credits banner also starts
    // with the word "xcross", and a false negative here would roll back a
    // perfectly good update.
    final reported = result.stdout
        .split(RegExp(r'\s+'))
        .map(XcrossSemver.tryParse)
        .nonNulls;
    if (result.exitCode != 0) {
      throw XcrossError(
        'the installed binary did not report a parseable xcross version for '
        '$label (exit ${result.exitCode}); restoring the previous version',
      );
    }
    if (expectedVersion != null) {
      if (!reported.contains(expectedVersion)) {
        throw XcrossError(
          'the installed binary did not report version $expectedVersion '
          '(exit ${result.exitCode}); restoring the previous version',
        );
      }
      return result;
    }
    if (reported.isEmpty) {
      throw XcrossError(
        'the installed binary did not report a parseable xcross version for '
        '$label (exit ${result.exitCode}); restoring the previous version',
      );
    }
    return result;
  }
}
