import 'package:args/command_runner.dart';
import 'package:xcross/src/build/flutter_pack_operation.dart';
import 'package:xcross/src/build/hot_reload_setup.dart';
import 'package:xcross/src/cli/flutter/flutter_build_args.dart';
import 'package:xcross/src/device/core_device_launcher.dart';
import 'package:xcross/src/device/debug_launcher.dart';
import 'package:xcross/src/device/os_version.dart';
import 'package:xcross/src/models/device/device.dart';
import 'package:xcross/src/models/flutter/flutter_build_options.dart';
import 'package:xcross/src/util/logging.dart';
import 'package:xcross/src/xtool/xtool_cli.dart';

/// How `--device-connection` restricts device discovery.
enum DeviceConnection { attached, wireless, both }

/// `xcross flutter run` — build, sign+install (via xtool), launch, and (for
/// iOS 17+ debug builds) hot-reload a Flutter app on a connected device.
///
/// Always builds a debug (JIT) app and always launches with hot reload (the
/// flutter default). Accepts a mix of the original xtool flags (`-u/--udid`,
/// `--usb/--wifi`) and the official `flutter run` flags (`-t/--target`,
/// `-d/--device-id`, `-D/--dart-define`, `--dart-define-from-file`,
/// `--[no-]pub`, `--route`, `-a/--dart-entrypoint-args`, `--device-connection`,
/// `--flavor`).
class FlutterRunCommand extends Command<void> with CommonFlutterOptions {
  FlutterRunCommand() {
    addCommonFlutterOptions();
    argParser
      ..addOption(
        'device-id',
        abbr: 'd',
        help: 'Target device id or name (flutter-style).',
      )
      ..addOption(
        'udid',
        abbr: 'u',
        help: 'Target device UDID (xtool-style).',
      )
      ..addFlag(
        'usb',
        help: 'Search USB devices only.',
        negatable: false,
      )
      ..addFlag(
        'wifi',
        help: 'Search Wi-Fi devices only.',
        negatable: false,
      )
      ..addOption(
        'device-connection',
        help: 'Discovery: attached (USB), wireless (Wi-Fi), or both.',
        defaultsTo: DeviceConnection.both.name,
        allowed: DeviceConnection.values.map((e) => e.name),
      )
      ..addOption(
        'route',
        help: 'Initial route the app navigates to on launch.',
      )
      ..addMultiOption(
        'dart-entrypoint-args',
        abbr: 'a',
        help: 'Pass arguments to the app main() (repeatable).',
      )
      ..addFlag(
        'verbose',
        abbr: 'v',
        help: 'Verbose output.',
        negatable: false,
      );
  }

  @override
  String get name => 'run';

  @override
  String get description =>
      'Build, install, and run a Flutter iOS app on a device.';

  String? get _route => argResults!.option('route');
  List<String> get _dartEntrypointArgs =>
      argResults!.multiOption('dart-entrypoint-args');
  bool get _verbose => argResults!.flag('verbose');

  String? get _deviceSelector =>
      argResults!.option('udid') ?? argResults!.option('device-id');

  /// `--usb`/`--wifi` win over `--device-connection`; changing that precedence
  /// changes which device an existing user command line targets.
  DeviceSearchMode get _searchMode {
    if (argResults!.flag('usb')) return DeviceSearchMode.usb;
    if (argResults!.flag('wifi')) return DeviceSearchMode.wifi;
    final connection = DeviceConnection.values
        .byName(argResults!.option('device-connection')!);
    return switch (connection) {
      DeviceConnection.attached => DeviceSearchMode.usb,
      DeviceConnection.wireless => DeviceSearchMode.wifi,
      DeviceConnection.both => DeviceSearchMode.all,
    };
  }

  /// App-level arguments passed to the launched binary (`--route`, then any
  /// `--dart-entrypoint-args`).
  List<String> get _appArguments => [
        if (_route case final route?) '--route=$route',
        ..._dartEntrypointArgs,
      ];

  @override
  Future<void> run() async {
    if (_verbose) setVerbose();

    final options = await FlutterBuildOptions.resolve(
      target: target,
      dartDefine: dartDefine,
      dartDefineFromFile: dartDefineFromFile,
      pub: pub,
      flavor: flavor,
    );
    final pack = await flutterPack(options: options);

    final xtool = XtoolCli();
    final device =
        await xtool.resolveDevice(selector: _deviceSelector, mode: _searchMode);
    logInfo('Device', '${device.name} ${ansi.subtle(device.udid)}');

    // iOS 17+ removed the classic lockdown debugserver: launch (and process
    // control) go through the CoreDevice/RSD tunnel. Determine this up front so
    // we can close a still-running instance before installing.
    final osMajor = await deviceOSMajorVersion(device.udid);
    final useCoreDevice = osMajor != null && osMajor >= 17;

    // Close the app if it happens to be running at install time, so the install
    // and relaunch don't collide with a live instance.
    if (useCoreDevice) {
      await CoreDeviceLauncher.terminateIfRunning(
          udid: device.udid, bundleId: pack.bundleId);
    }

    // Renders its own spinner + grey log tail (see [XtoolCli.install]).
    await xtool.install(pack.appPath, udid: device.udid, mode: _searchMode);

    await _launch(
      pack: pack,
      device: device,
      useCoreDevice: useCoreDevice,
      dartDefines: options.dartDefines,
      xtool: xtool,
    );
  }

  /// Launch the freshly installed app: CoreDevice/RSD on iOS 17+ (with hot
  /// reload when available), otherwise the classic debugserver path.
  Future<void> _launch({
    required PackResult pack,
    required Device device,
    required bool useCoreDevice,
    required List<String> dartDefines,
    required XtoolCli xtool,
  }) async {
    // Flutter debug runs the Dart VM in JIT mode, which only works while a
    // debugger is attached (CS_DEBUGGED). run is always debug → stay attached.
    if (!useCoreDevice) {
      logInfo('App', '${pack.bundleId} ${ansi.subtle('debug/JIT')}');
      await DebugLauncher.launch(
        udid: device.udid,
        bundleId: pack.bundleId,
        xtool: xtool,
      );
      return;
    }

    // Always hot reload (flutter default). Degrades to attach-only if a
    // frontend_server artifact is missing.
    final hotReload = await buildHotReloadConfig(
      target: target,
      dartDefines: dartDefines,
      verbose: _verbose,
    );

    final mode = hotReload != null
        ? 'debug/JIT, hot reload'
        : 'debug/JIT, attached via CoreDevice';
    logInfo('App', '${pack.bundleId} ${ansi.subtle(mode)}');

    await CoreDeviceLauncher.launch(
      udid: device.udid,
      bundleId: pack.bundleId,
      arguments: _appArguments,
      hotReload: hotReload,
    );
  }
}
