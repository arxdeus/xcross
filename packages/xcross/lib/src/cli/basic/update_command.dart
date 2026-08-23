import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/update/git_ref_source_bundle_builder.dart';
import 'package:xcross/src/update/git_update_ref_resolver.dart';
import 'package:xcross/src/update/install_layout.dart';
import 'package:xcross/src/update/release_lookup.dart';
import 'package:xcross/src/update/self_update.dart';
import 'package:xcross/src/update/semver.dart';
import 'package:xcross/src/version.dart';

part 'update_command.g.dart';

typedef UpdateLatestTagLookup = Future<String> Function();
typedef UpdateRefResolver = Future<GitUpdateRef> Function(String ref);
typedef UpdateLayoutResolver = InstallLayout Function();
typedef UpdateAssetNameResolver = String Function();
typedef UpdateReleaseInstaller =
    Future<void> Function({required InstallLayout layout, required String tag});
typedef UpdateSourceInstaller =
    Future<void> Function({
      required InstallLayout layout,
      required GitUpdateRef ref,
    });
typedef UpdateResolvedRefReporter =
    void Function({
      required String requestedRef,
      required GitUpdateRef resolvedRef,
    });
typedef UpdateCurrentVersion = String Function();

/// Options for `xcross update`.
@CliOptions(createCommand: true)
final class UpdateArgs {
  @CliOption(
    negatable: false,
    help: 'Report the target version or resolved git ref without installing.',
  )
  late bool check;

  @CliOption(
    valueHelp: 'ref',
    help:
        'Install a specific git ref such as a release tag, branch, or commit.',
  )
  late String? ref;

  @CliOption(
    negatable: false,
    help: 'Reinstall even when the running version is already current.',
  )
  late bool force;

  @CliOption(abbr: 'y', negatable: false, help: 'Skip the confirmation prompt.')
  late bool yes;
}

/// `xcross update` — replace the installed xcross with a published release.
///
/// Release archives are verified against `SHA256SUMS.txt` before any file is
/// touched. Non-tag refs are built from source and then installed atomically.
final class UpdateCommand extends _$UpdateArgsCommand<void> {
  UpdateCommand()
    : this.withSeams(
        latestTagLookup: _defaultLatestTag,
        resolveRef: GitUpdateRefResolver().resolve,
        resolveInstallLayout: InstallLayout.resolve,
        assetName: SelfUpdate.assetName,
        installRelease: _defaultInstallRelease,
        installSourceRef: _defaultInstallSourceRef,
        reportResolvedRef: _defaultReportResolvedRef,
        currentVersion: () => XcrossVersion.current,
      );

  UpdateCommand.withSeams({
    UpdateLatestTagLookup? latestTagLookup,
    UpdateRefResolver? resolveRef,
    UpdateLayoutResolver? resolveInstallLayout,
    UpdateAssetNameResolver? assetName,
    UpdateReleaseInstaller? installRelease,
    UpdateSourceInstaller? installSourceRef,
    UpdateResolvedRefReporter? reportResolvedRef,
    UpdateCurrentVersion? currentVersion,
  }) : _latestTagLookup = latestTagLookup ?? _defaultLatestTag,
       _resolveRef = resolveRef ?? GitUpdateRefResolver().resolve,
       _resolveInstallLayout = resolveInstallLayout ?? InstallLayout.resolve,
       _assetName = assetName ?? SelfUpdate.assetName,
       _releaseInstaller = installRelease ?? _defaultInstallRelease,
       _sourceInstaller = installSourceRef ?? _defaultInstallSourceRef,
       _resolvedRefReporter = reportResolvedRef ?? _defaultReportResolvedRef,
       _currentVersion = currentVersion ?? (() => XcrossVersion.current);

  final UpdateLatestTagLookup _latestTagLookup;
  final UpdateRefResolver _resolveRef;
  final UpdateLayoutResolver _resolveInstallLayout;
  final UpdateAssetNameResolver _assetName;
  final UpdateReleaseInstaller _releaseInstaller;
  final UpdateSourceInstaller _sourceInstaller;
  final UpdateResolvedRefReporter _resolvedRefReporter;
  final UpdateCurrentVersion _currentVersion;

  @override
  String get name => 'update';

  @override
  String get description =>
      'Update xcross to the latest release or install an explicit git ref.';

  @override
  Future<void> run() async {
    final args = _options;
    final requestedRef = args.ref;
    if (requestedRef != null) {
      await _runExplicitRef(
        requestedRef,
        checkOnly: args.check,
        skipPrompt: args.yes,
      );
      return;
    }

    final tag = await _latestTagLookup();
    final target = _parseTag(tag);

    if (args.check) {
      _reportComparison(tag: tag, target: target);
      return;
    }

    if (!args.force && !_isUpgrade(target)) {
      Log.logDone('xcross ${_currentVersion()} is already the latest');
      return;
    }

    final layout = _resolveInstallLayout();
    final asset = _assetName();
    Log.logInfo('Release', '$tag (installed: ${_currentVersion()})');
    Log.logInfo('Asset', asset);
    if (!_confirm(target: tag, skipPrompt: args.yes)) {
      Log.logStatus('Aborted.');
      return;
    }

    await _releaseInstaller(layout: layout, tag: tag);
    Log.logDone('Updated xcross to $tag', layout.binaryPath);
  }

  Future<void> _runExplicitRef(
    String requestedRef, {
    required bool checkOnly,
    required bool skipPrompt,
  }) async {
    final resolvedRef = await _resolveRef(requestedRef);
    if (checkOnly) {
      _resolvedRefReporter(
        requestedRef: requestedRef,
        resolvedRef: resolvedRef,
      );
      return;
    }

    final target = resolvedRef.displayName;
    Log.logInfo('Ref', '$requestedRef -> ${resolvedRef.displayName}');
    Log.logInfo('Kind', resolvedRef.kind.name);
    Log.logInfo('Commit', resolvedRef.commitSha);
    if (!_confirm(target: target, skipPrompt: skipPrompt)) {
      Log.logStatus('Aborted.');
      return;
    }

    final layout = _resolveInstallLayout();
    if (resolvedRef.kind == GitUpdateRefKind.tag) {
      _parseTag(resolvedRef.displayName);
      final asset = _assetName();
      Log.logInfo('Asset', asset);
      await _releaseInstaller(layout: layout, tag: resolvedRef.displayName);
      Log.logDone(
        'Updated xcross to ${resolvedRef.displayName}',
        layout.binaryPath,
      );
      return;
    }

    await _sourceInstaller(layout: layout, ref: resolvedRef);
    Log.logDone(
      'Updated xcross to ${resolvedRef.displayName} (${resolvedRef.commitSha})',
      layout.binaryPath,
    );
  }

  XcrossSemver _parseTag(String tag) {
    final target = XcrossSemver.tryParse(tag);
    if (target == null) {
      throw XcrossError('release tag "$tag" is not a version xcross can read');
    }
    return target;
  }

  void _reportComparison({required String tag, required XcrossSemver target}) {
    if (_isUpgrade(target)) {
      Log.logInfo('xcross $tag is available (installed: ${_currentVersion()})');
      Log.logStatus("Run 'xcross update' to install it.");
      return;
    }
    Log.logDone(
      'xcross $tag is the latest version (installed: ${_currentVersion()})',
    );
  }

  bool _isUpgrade(XcrossSemver target) {
    final current = XcrossSemver.tryParse(_currentVersion());
    return current == null || target.isNewerThan(current);
  }

  /// A non-interactive shell cannot answer, so it is treated as consent: the
  /// user explicitly ran `xcross update` to get exactly this.
  static bool _confirm({required String target, required bool skipPrompt}) {
    if (skipPrompt || !stdin.hasTerminal) return true;
    stdout.write('Update xcross to $target? [y/N] ');
    final answer = stdin.readLineSync()?.trim().toLowerCase();
    return answer == 'y' || answer == 'yes';
  }

  static Future<String> _defaultLatestTag() =>
      Log.logStep('Checking for updates', ReleaseLookup.latestTag);

  static Future<void> _defaultInstallRelease({
    required InstallLayout layout,
    required String tag,
  }) => SelfUpdate.apply(layout: layout, tag: tag);

  static Future<void> _defaultInstallSourceRef({
    required InstallLayout layout,
    required GitUpdateRef ref,
  }) {
    final builder = GitRefSourceBundleBuilder();
    return builder.build<void>(
      ref: ref,
      onBundle: (bundleRoot) => SelfUpdate.installBundle(
        bundleRoot: bundleRoot,
        layout: layout,
        label: 'xcross ${ref.displayName} (${ref.commitSha})',
      ),
    );
  }

  static void _defaultReportResolvedRef({
    required String requestedRef,
    required GitUpdateRef resolvedRef,
  }) {
    Log.logInfo('Requested ref', requestedRef);
    Log.logInfo('Resolved ref', resolvedRef.displayName);
    Log.logInfo('Kind', resolvedRef.kind.name);
    Log.logInfo('Commit', resolvedRef.commitSha);
  }
}
