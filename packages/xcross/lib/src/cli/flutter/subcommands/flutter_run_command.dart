import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:xcross/src/cli/flutter/subcommands/flutter_build_command.dart';
import 'package:xcross/src/device/core_device_launch_profile.dart';
import 'package:xcross/src/device/device_run_operation.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/flutter/flutter.dart';

part 'flutter_run_command.g.dart';

/// How `--device-connection` restricts device discovery.
enum DeviceConnection { attached, wireless, both }

/// Options for `xcross flutter run`.
@CliOptions(createCommand: true)
final class FlutterRunArgs extends CommonFlutterArgs {
  @CliOption(abbr: 'd', help: 'Target device id or name (flutter-style).')
  late String? deviceId;

  @CliOption(abbr: 'u', help: 'Target device UDID.')
  late String? udid;

  @CliOption(help: 'Search USB devices only.', negatable: false)
  late bool usb;

  @CliOption(help: 'Search Wi-Fi devices only.', negatable: false)
  late bool wifi;

  @CliOption(
    defaultsTo: DeviceConnection.both,
    help: 'Discovery: attached (USB), wireless (Wi-Fi), or both.',
  )
  late DeviceConnection deviceConnection;

  @CliOption(help: 'Initial route the app navigates to on launch.')
  late String? route;

  @CliOption(abbr: 'a', help: 'Pass arguments to the app main() (repeatable).')
  late List<String> dartEntrypointArgs;

  @CliOption(abbr: 'v', help: 'Verbose output.', negatable: false)
  late bool verbose;
}

/// `xcross flutter run` — build, sign, install, launch, and hot-reload a
/// Flutter app on a connected iOS 17+ device.
///
/// Always builds a debug (JIT) app and always launches with hot reload (the
/// flutter default).
final class FlutterRunCommand extends _$FlutterRunArgsCommand<void> {
  static bool shouldUseCoreDevice(int? osMajor) =>
      osMajor == null || osMajor >= 17;

  @override
  String get name => 'run';

  @override
  String get description =>
      'Build, install, and run a Flutter iOS app on a device.';

  String? get _deviceSelector => _options.udid ?? _options.deviceId;

  /// `--usb`/`--wifi` win over `--device-connection`; changing that precedence
  /// changes which device an existing user command line targets.
  DeviceSearchMode get _searchMode {
    if (_options.usb) return DeviceSearchMode.usb;
    if (_options.wifi) return DeviceSearchMode.wifi;
    return switch (_options.deviceConnection) {
      DeviceConnection.attached => DeviceSearchMode.usb,
      DeviceConnection.wireless => DeviceSearchMode.wifi,
      DeviceConnection.both => DeviceSearchMode.all,
    };
  }

  /// App-level arguments passed to the launched binary (`--route`, then any
  /// `--dart-entrypoint-args`).
  List<String> get _appArguments => [
    if (_options.route case final route?) '--route=$route',
    ..._options.dartEntrypointArgs,
  ];

  @override
  Future<void> run() async {
    if (_options.verbose) Log.setVerbose();

    final options = await FlutterBuildOptions.resolve(
      target: _options.target,
      dartDefine: _options.dartDefine,
      dartDefineFromFile: _options.dartDefineFromFile,
      pub: _options.pub,
      flavor: _options.flavor,
    );
    final pack = await FlutterPackOperation.pack(options: options);

    final hotReload = await HotReloadSetup.buildHotReloadConfig(
      target: _options.target,
      dartDefines: options.dartDefines,
      verbose: _options.verbose,
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

    final operation = await DeviceRunOperation.resolve();
    await operation.run(
      pack: pack,
      selector: _deviceSelector,
      mode: _searchMode,
      launchProfile: CoreDeviceLaunchProfile.flutter(
        arguments: _appArguments,
        hotReload: hotReload,
      ),
    );
  }
}
