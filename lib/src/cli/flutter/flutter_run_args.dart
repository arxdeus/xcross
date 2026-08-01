import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:xcross/src/build/flutter_pack_operation.dart';
import 'package:xcross/src/build/hot_reload_setup.dart';
import 'package:xcross/src/cli/flutter/flutter_build_args.dart';
import 'package:xcross/src/device/core_device_launcher.dart';
import 'package:xcross/src/device/device_backend.dart';
import 'package:xcross/src/device/os_version.dart';
import 'package:xcross/src/models/device/device.dart';
import 'package:xcross/src/models/flutter/flutter_build_options.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';

/// How `--device-connection` restricts device discovery.
enum DeviceConnection { attached, wireless, both }

/// `xcross flutter run` — build, sign, install, launch, and hot-reload a
/// Flutter app on a connected iOS 17+ device.
///
/// Always builds a debug (JIT) app and always launches with hot reload (the
/// flutter default). Accepts device-selection flags (`-u/--udid`,
/// `--usb/--wifi`) and the official `flutter run` flags (`-t/--target`,
/// `-d/--device-id`, `-D/--dart-define`, `--dart-define-from-file`,
/// `--[no-]pub`, `--route`, `-a/--dart-entrypoint-args`, `--device-connection`,
/// `--flavor`).
bool shouldUseCoreDevice(int? osMajor) => osMajor == null || osMajor >= 17;

class FlutterRunCommand extends Command<void> with CommonFlutterOptions {
  FlutterRunCommand() {
    addCommonFlutterOptions();
    argParser
      ..addOption(
        'device-id',
        abbr: 'd',
        help: 'Target device id or name (flutter-style).',
      )
      ..addOption('udid', abbr: 'u', help: 'Target device UDID.')
      ..addFlag('usb', help: 'Search USB devices only.', negatable: false)
      ..addFlag('wifi', help: 'Search Wi-Fi devices only.', negatable: false)
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
    final connection = DeviceConnection.values.byName(
      argResults!.option('device-connection')!,
    );
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
    if (_verbose) Log.setVerbose();

    final options = await FlutterBuildOptions.resolve(
      target: target,
      dartDefine: dartDefine,
      dartDefineFromFile: dartDefineFromFile,
      pub: pub,
      flavor: flavor,
    );
    final pack = await FlutterPackOperation.pack(options: options);

    final backend = await DeviceBackend.resolve();
    final device = await backend.resolveDevice(
      selector: _deviceSelector,
      mode: _searchMode,
    );
    Log.logInfo('Device', '${device.name} ${Log.ansi.subtle(device.udid)}');

    // iOS 17+ launch and process control go through the CoreDevice/RSD tunnel.
    // Fail before install when the device is known to be unsupported.
    final osMajor = await OsVersion.deviceOSMajorVersion(device.udid);
    if (!shouldUseCoreDevice(osMajor)) {
      throw XcrossError(
        'Native device launching requires iOS 17 or later; update this device '
        'before running the app.',
      );
    }
    if (osMajor == null) {
      Log.logWarn(
        'Could not read the device OS version; attempting the native '
        'CoreDevice path.',
      );
    }

    // Close the app if it happens to be running at install time, so the install
    // and relaunch don't collide with a live instance.
    await CoreDeviceLauncher.terminateIfRunning(
      udid: device.udid,
      bundleId: pack.bundleId,
    );

    await backend.install(
      pack.appPath,
      udid: device.udid,
      mode: _searchMode,
      bundleId: pack.bundleId,
    );

    await _launch(pack: pack, device: device, dartDefines: options.dartDefines);
  }

  /// Launch the freshly installed app through CoreDevice/RSD, with hot reload
  /// when available.
  Future<void> _launch({
    required PackResult pack,
    required Device device,
    required List<String> dartDefines,
  }) async {
    // Always hot reload (flutter default). Degrades to attach-only if a
    // frontend_server artifact is missing.
    final hotReload = await HotReloadSetup.buildHotReloadConfig(
      target: target,
      dartDefines: dartDefines,
      verbose: _verbose,
    );
    if (hotReload == null && Platform.environment['XCROSS_DAP'] == '1') {
      throw XcrossError(
        'DAP launch requires the Flutter frontend_server artifacts needed '
        'for hot reload.',
      );
    }

    final mode = hotReload != null
        ? 'debug/JIT, hot reload'
        : 'debug/JIT, attached via CoreDevice';
    Log.logInfo('App', '${pack.bundleId} ${Log.ansi.subtle(mode)}');

    await CoreDeviceLauncher.launch(
      udid: device.udid,
      bundleId: pack.bundleId,
      arguments: _appArguments,
      hotReload: hotReload,
    );
  }
}
