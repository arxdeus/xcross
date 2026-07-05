import 'package:args/command_runner.dart';
import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:xcross/src/cli/compose/compose_operations.dart';
import 'package:xcross/src/device/core_device_launcher.dart';
import 'package:xcross/src/device/debug_launcher.dart';
import 'package:xcross/src/device/os_version.dart';
import 'package:xcross/src/models/compose/compose_options.dart';
import 'package:xcross/src/util/logging.dart';
import 'package:xcross/src/xtool/xtool_cli.dart';

part 'compose_run_args.g.dart';

@CliOptions(createCommand: true)
class ComposeRunArgs {
  const ComposeRunArgs({
    this.configuration = ComposeConfiguration.debug,
    this.deviceId,
    this.udid,
    this.usb = false,
    this.network = false,
    this.dartEntrypointArgs = const [],
  });

  @CliOption(
    abbr: 'c',
    defaultsTo: ComposeConfiguration.debug,
    help: 'Build configuration (debug default for run).',
  )
  final ComposeConfiguration configuration;

  @CliOption(
    abbr: 'd',
    name: 'device-id',
    help: 'Target device id or name (flutter-style).',
  )
  final String? deviceId;

  @CliOption(
    abbr: 'u',
    help: 'Target device UDID (xtool-style).',
  )
  final String? udid;

  @CliOption(
    negatable: false,
    help: 'Search USB-connected devices only.',
  )
  final bool usb;

  @CliOption(
    negatable: false,
    help: 'Search Wi-Fi / network devices only.',
  )
  final bool network;

  @CliOption(
    abbr: 'a',
    name: 'dart-entrypoint-args',
    help: 'Arguments passed to the app binary (repeatable).',
  )
  final List<String> dartEntrypointArgs;
}

/// `xcross compose run` — build, sign+install, and launch a KMP iOS app.
///
/// Defaults to debug configuration. Reuses the same device/launch stack as
/// `xcross flutter run` (XtoolCli → CoreDeviceLauncher on iOS 17+,
/// DebugLauncher on pre-17). Compose hot reload is TBD; keepAttached is always
/// true so the K-N JIT/debug binary keeps its CS_DEBUGGED flag.
///
/// Mirrors ComposeRunCommand from ComposeCommand.swift, adapted for the xcross
/// device stack.
class ComposeRunCommand extends _$ComposeRunArgsCommand<void> {
  @override
  String get name => 'run';

  @override
  String get description =>
      'Build, install, and run a Kotlin (Compose) Multiplatform iOS app.';

  String? get _deviceSelector => _options.udid ?? _options.deviceId;

  DeviceSearchMode get _searchMode {
    if (_options.usb) return DeviceSearchMode.usb;
    if (_options.network) return DeviceSearchMode.wifi;
    return DeviceSearchMode.all;
  }

  List<String> get _appArguments => _options.dartEntrypointArgs;

  @override
  Future<void> run() async {
    // 1. Build the KMP iOS .app via pipeline.sh.
    // S1: requireRunnableApp=true → throws early for frameworkOnly projects
    // with a clear message before we'd try to install a bare .framework.
    final pack = await composePack(
      options: ComposeOptions(configuration: _options.configuration),
      requireRunnableApp: true,
    );

    // 2. Resolve target device + sign/install via the original xtool.
    final xtool = XtoolCli();
    final device = await xtool.resolveDevice(
      selector: _deviceSelector,
      mode: _searchMode,
    );
    logStatus(
      '[xtool] installing to device: ${device.name} (udid: ${device.udid})',
    );

    // 3. Gate on iOS version: 17+ uses CoreDevice/RSD, older uses debugserver.
    final osMajor = await deviceOSMajorVersion(device.udid);
    final useCoreDevice = osMajor != null && osMajor >= 17;

    // 4. Terminate any running instance before installing to avoid collisions.
    if (useCoreDevice) {
      await CoreDeviceLauncher.terminateIfRunning(
        udid: device.udid,
        bundleId: pack.bundleId,
      );
    }

    // 5. Install (signs at install time via xtool auth credentials).
    await xtool.install(pack.appPath, udid: device.udid, mode: _searchMode);

    // K-N debug apps need CS_DEBUGGED (same requirement as Flutter JIT) —
    // always stay attached so the app doesn't get SIGKILL'd on detach.
    const keepAttached = true;

    if (useCoreDevice) {
      const hint = ' (debug — staying attached via CoreDevice)';
      logStatus('[xcross] launching ${pack.bundleId}$hint...');
      await CoreDeviceLauncher.launch(
        udid: device.udid,
        bundleId: pack.bundleId,
        arguments: _appArguments,
        keepAttached: keepAttached,
        // K-N doesn't use Flutter's --enable-checked-mode / --verify-entry-points.
        checkedMode: false,
        // Compose hot reload is not yet implemented.
      );
      return;
    }

    // Pre-iOS-17 path — delegate to `xtool launch` via DebugLauncher.
    logStatus(
      '[xcross] launching ${pack.bundleId} '
      '(debug — staying attached via debugserver)...',
    );
    await DebugLauncher.launch(
      udid: device.udid,
      bundleId: pack.bundleId,
      keepAttached: keepAttached,
      xtool: xtool,
    );
  }
}
