import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/cli/internal/parsed_command.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/setup/setup_script.dart';
import 'package:xcross/src/shared/cli/command_prompt.dart';
import 'package:xcross/src/shared/runtime/xcross_runtime.dart';
import 'package:xcross/src/update/git_ref_source_bundle_builder.dart';
import 'package:xcross/src/update/git_update_ref_resolver.dart';
import 'package:xcross/src/update/install_layout.dart';
import 'package:xcross/src/update/self_update.dart';
import 'package:xcross/src/update/semver.dart';
import 'package:xcross/src/version.dart';

part 'update_command.g.dart';

/// Options for `xcross update`.
@CliOptions()
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
final class UpdateCommand extends ParsedCommand<UpdateArgs, void> {
  @override
  ArgParser populateOptions(ArgParser parser) =>
      _$populateUpdateArgsParser(parser);
  @override
  UpdateArgs parseOptions(ArgResults results) =>
      _$parseUpdateArgsResult(results);

  UpdateCommand(XcrossRuntime runtime) : this.withSeams(runtime);

  UpdateCommand.withSeams(
    XcrossRuntime runtime, {
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
    bool Function(InstallLayout layout)? hasNativeLibraries,
    Future<void> Function()? refreshSetupScript,
  }) : commandPrompt = runtime.commandPrompt,
       log = runtime.log,
       _latestTagLookup = _withLatestTagStep(
         runtime.log,
         latestTagLookup ??
             (() => runtime.releaseLookup.latestTag(
               environment: runtime.runner.effectiveEnvironment,
             )),
       ),
       _resolveRef = _withResolveRefStep(
         runtime.log,
         resolveRef ??
             (ref) => GitUpdateRefResolver(runner: runtime.runner).resolve(ref),
       ),
       _resolveInstallLayout =
           resolveInstallLayout ??
           (() =>
               InstallLayout.resolve(runtime.executable, host: runtime.host)),
       _assetName =
           assetName ??
           SelfUpdate(
             host: runtime.host,
             runner: runtime.runner,
             downloader: runtime.downloader,
             policy: runtime.operations.update,
           ).assetName,
       _releaseInstaller =
           installRelease ??
           SelfUpdate(
             host: runtime.host,
             runner: runtime.runner,
             downloader: runtime.downloader,
             policy: runtime.operations.update,
           ).apply,
       _sourceInstaller =
           installSourceRef ??
           (({required layout, required ref}) =>
               _defaultInstallSourceRef(runtime, layout: layout, ref: ref)),
       _resolvedRefReporter =
           reportResolvedRef ??
           (({required requestedRef, required resolvedRef}) =>
               _defaultReportResolvedRef(
                 log: runtime.log,
                 requestedRef: requestedRef,
                 resolvedRef: resolvedRef,
               )),
       _currentVersion = currentVersion ?? _defaultCurrentVersion,
       _currentIsReleased = currentIsReleased ?? _defaultCurrentIsReleased,
       _hasNativeLibraries =
           hasNativeLibraries ?? ((layout) => layout.hasNativeLibraries),
       _refreshSetupScript =
           refreshSetupScript ?? (() => _defaultRefreshSetupScript(runtime));

  final Log log;
  final CommandPrompt commandPrompt;
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
  final bool Function(InstallLayout layout) _hasNativeLibraries;
  final Future<void> Function() _refreshSetupScript;

  @override
  String get name => 'update';

  @override
  String get description =>
      'Update xcross to the latest release or install an explicit git ref.';

  @override
  Future<void> run() async {
    final args = options;
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

    final layout = _resolveInstallLayout();
    final hasNativeLibraries = _hasNativeLibraries(layout);
    if (!args.force && !_isUpgrade(target) && hasNativeLibraries) {
      log.logDone('xcross ${_currentVersion()} is already the latest');
      return;
    }

    if (!hasNativeLibraries) {
      log.logWarn('Native libraries are missing; reinstalling $tag');
    }
    final asset = _assetName();
    log.logInfo('Release', '$tag (installed: ${_currentVersion()})');
    log.logInfo('Asset', asset);
    if (!_confirm(target: tag, skipPrompt: args.yes)) {
      log.logStatus('Aborted.');
      return;
    }

    await _releaseInstaller(layout: layout, tag: tag);
    await _refreshSetupScript();
    log.logDone('Updated xcross to $tag', layout.binaryPath);
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
    log.logInfo('Ref', '$requestedRef -> ${resolvedRef.displayName}');
    log.logInfo('Kind', resolvedRef.kind.name);
    log.logInfo('Commit', resolvedRef.commitSha);
    if (!_confirm(target: target, skipPrompt: skipPrompt)) {
      log.logStatus('Aborted.');
      return;
    }

    final layout = _resolveInstallLayout();
    if (resolvedRef.kind == GitUpdateRefKind.tag) {
      _parseTag(resolvedRef.displayName);
      final asset = _assetName();
      log.logInfo('Asset', asset);
      await _releaseInstaller(layout: layout, tag: resolvedRef.displayName);
      await _refreshSetupScript();
      log.logDone(
        'Updated xcross to ${resolvedRef.displayName}',
        layout.binaryPath,
      );
      return;
    }

    await _sourceInstaller(layout: layout, ref: resolvedRef);
    await _refreshSetupScript();
    log.logDone(
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
      log.logInfo('xcross $tag is available (installed: ${_currentVersion()})');
      log.logStatus("Run 'xcross update' to install it.");
      return;
    }
    log.logDone(
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
  bool _confirm({required String target, required bool skipPrompt}) {
    if (skipPrompt || !commandPrompt.isInteractive) return true;
    final answer = commandPrompt
        .readLine('Update xcross to $target? [y/N] ')
        ?.trim()
        .toLowerCase();
    return answer == 'y' || answer == 'yes';
  }

  static Future<String> Function() _withLatestTagStep(
    Log log,
    Future<String> Function() lookup,
  ) =>
      () => log.logStep('Checking latest release', lookup);

  static Future<GitUpdateRef> Function(String ref) _withResolveRefStep(
    Log log,
    Future<GitUpdateRef> Function(String ref) resolve,
  ) =>
      (ref) => log.logStep('Resolving ref $ref', () => resolve(ref));

  static String _defaultCurrentVersion() => XcrossVersion.current;

  static bool _defaultCurrentIsReleased() => XcrossVersion.isReleased;

  static Future<void> _defaultRefreshSetupScript(XcrossRuntime runtime) async {
    final manager = SetupScriptManager(
      createHttpClient: runtime.createHttpClient,
      host: runtime.host,
      runner: runtime.runner,
      policy: runtime.operations.setupScript,
      source: runtime.config.config?.setup,
    );
    if (manager.isRemote) await manager.refresh();
  }

  static Future<void> _defaultInstallSourceRef(
    XcrossRuntime runtime, {
    required InstallLayout layout,
    required GitUpdateRef ref,
  }) {
    final builder = GitRefSourceBundleBuilder(
      runner: runtime.runner,
      acceptDartLauncher: runtime.operations.acceptDartLauncher,
    );
    return builder.build<void>(
      ref: ref,
      onBundle: (bundleRoot, progress) =>
          SelfUpdate(
            host: runtime.host,
            runner: runtime.runner,
            downloader: runtime.downloader,
            policy: runtime.operations.update,
          ).installBundle(
            bundleRoot: bundleRoot,
            layout: layout,
            label: 'xcross ${ref.displayName} (${ref.commitSha})',
            expectedIdentity: ref.displayName,
            progress: progress,
          ),
    );
  }

  static void _defaultReportResolvedRef({
    required Log log,
    required String requestedRef,
    required GitUpdateRef resolvedRef,
  }) {
    log.logInfo('Requested ref', requestedRef);
    log.logInfo('Resolved ref', resolvedRef.displayName);
    log.logInfo('Kind', resolvedRef.kind.name);
    log.logInfo('Commit', resolvedRef.commitSha);
  }
}
