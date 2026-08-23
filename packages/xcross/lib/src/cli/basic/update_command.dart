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
        'Install a specific git ref such as a release tag, branch, or full '
        '40-character commit SHA.',
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
  UpdateCommand() : this.withSeams();

  UpdateCommand.withSeams({
    Future<String> Function()? latestTagLookup,
    Future<GitUpdateRef> Function(String ref)? resolveRef,
    InstallLayout Function()? resolveInstallLayout,
    String Function()? assetName,
    Future<void> Function({required InstallLayout layout, required String tag})?
    installRelease,
    Future<void> Function({
      required InstallLayout layout,
      required GitUpdateRef ref,
    })?
    installSourceRef,
    void Function({
      required String requestedRef,
      required GitUpdateRef resolvedRef,
    })?
    reportResolvedRef,
    String Function()? currentVersion,
    bool Function()? currentIsReleased,
  }) : _latestTagLookup = _withLatestTagStep(
         latestTagLookup ?? ReleaseLookup.latestTag,
       ),
       _resolveRef = _withResolveRefStep(
         resolveRef ?? (ref) => GitUpdateRefResolver().resolve(ref),
       ),
       _resolveInstallLayout =
           resolveInstallLayout ?? _defaultResolveInstallLayout,
       _assetName = assetName ?? _defaultAssetName,
       _releaseInstaller = installRelease ?? _defaultInstallRelease,
       _sourceInstaller = installSourceRef ?? _defaultInstallSourceRef,
       _resolvedRefReporter = reportResolvedRef ?? _defaultReportResolvedRef,
       _currentVersion = currentVersion ?? _defaultCurrentVersion,
       _currentIsReleased = currentIsReleased ?? _defaultCurrentIsReleased;

  final Future<String> Function() _latestTagLookup;
  final Future<GitUpdateRef> Function(String ref) _resolveRef;
  final InstallLayout Function() _resolveInstallLayout;
  final String Function() _assetName;
  final Future<void> Function({
    required InstallLayout layout,
    required String tag,
  })
  _releaseInstaller;
  final Future<void> Function({
    required InstallLayout layout,
    required GitUpdateRef ref,
  })
  _sourceInstaller;
  final void Function({
    required String requestedRef,
    required GitUpdateRef resolvedRef,
  })
  _resolvedRefReporter;
  final String Function() _currentVersion;
  final bool Function() _currentIsReleased;

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
    if (!_currentIsReleased()) return true;
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

  static Future<String> Function() _withLatestTagStep(
    Future<String> Function() lookup,
  ) =>
      () => Log.logStep('Checking latest release', lookup);

  static Future<GitUpdateRef> Function(String ref) _withResolveRefStep(
    Future<GitUpdateRef> Function(String ref) resolve,
  ) =>
      (ref) => Log.logStep('Resolving ref $ref', () => resolve(ref));

  static InstallLayout _defaultResolveInstallLayout() =>
      InstallLayout.resolve();

  static String _defaultAssetName() => SelfUpdate.assetName();

  static String _defaultCurrentVersion() => XcrossVersion.current;

  static bool _defaultCurrentIsReleased() => XcrossVersion.isReleased;

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
      onBundle: (bundleRoot, progress) => SelfUpdate.installBundle(
        bundleRoot: bundleRoot,
        layout: layout,
        label: 'xcross ${ref.displayName} (${ref.commitSha})',
        expectedIdentity: ref.displayName,
        expectedReleased: false,
        progress: progress,
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
