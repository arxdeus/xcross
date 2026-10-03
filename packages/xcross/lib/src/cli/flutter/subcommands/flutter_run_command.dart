import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:cli_kit/cli_kit_shared.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart' show Pymd;
import 'package:dart_mobile_device/dart_mobile_device_shared.dart'
    show DeviceSearchMode, DeviceSockets;
import 'package:xcross/src/cli/flutter/subcommands/flutter_build_command.dart';
import 'package:xcross/src/cli/internal/parsed_command.dart';
import 'package:xcross/src/cli/shared/device_selection.dart';
import 'package:xcross/src/composition/ios_target.dart';
import 'package:xcross/src/device/core_device_launch_profile.dart';
import 'package:xcross/src/device/device_run_operation.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/flutter/flutter.dart';
import 'package:xcross/src/shared/runtime/xcross_runtime.dart';
import 'package:xcross/src/target/shared/runtime/build_features.dart';

part 'flutter_run_command.g.dart';

/// Options for `xcross flutter run`.
@CliOptions()
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
final class FlutterRunCommand<T extends PlatformHostInterface>
    extends ParsedCommand<FlutterRunArgs, void> {
  @override
  ArgParser populateOptions(ArgParser parser) =>
      _$populateFlutterRunArgsParser(parser);
  @override
  FlutterRunArgs parseOptions(ArgResults results) =>
      _$parseFlutterRunArgsResult(results);

  FlutterRunCommand(this.runtime, this.pymd, {required this.sockets})
    : features = composePhysicalFeatures(runtime);

  final XcrossBuildFeatures<T> features;

  final XcrossRuntime<T> runtime;
  final Pymd pymd;
  final DeviceSockets sockets;
  static bool shouldUseCoreDevice(int? osMajor) =>
      osMajor == null || osMajor >= 17;

  @override
  String get name => 'run';

  @override
  String get description =>
      'Build, install, and run a Flutter iOS app on a device.';

  String? get _deviceSelector => options.udid ?? options.deviceId;

  /// `--usb`/`--wifi` win over `--device-connection`; changing that precedence
  /// changes which device an existing user command line targets.
  DeviceSearchMode get _searchMode => deviceSearchMode(
    usb: options.usb,
    wifi: options.wifi,
    deviceConnection: options.deviceConnection,
  );

  /// App-level arguments passed to the launched binary (`--route`, then any
  /// `--dart-entrypoint-args`).
  List<String> get _appArguments => [
    if (options.route case final route?) '--route=$route',
    ...options.dartEntrypointArgs,
  ];

  @override
  Future<void> run() async {
    if (options.verbose) runtime.log.setVerbose();

    final buildRuntime = features.flutterRuntime;
    final buildOptions = await buildRuntime.options.resolve(
      target: options.target,
      dartDefine: options.dartDefine,
      dartDefineFromFile: options.dartDefineFromFile,
      pub: options.pub,
      flavor: options.flavor,
    );
    final pack = await FlutterPackOperation.pack(
      projectRoot: runtime.host.paths.context.current,
      runtime: buildRuntime,
      options: buildOptions,
    );

    final hotReload = await HotReloadSetup.buildHotReloadConfig(
      projectRoot: runtime.host.paths.context.current,
      runtime: buildRuntime,
      target: buildOptions.target,
      dartDefines: buildOptions.dartDefines,
      verbose: options.verbose,
    );
    if (hotReload == null &&
        runtime.runner.effectiveEnvironment['XCROSS_DAP'] == '1') {
      throw XcrossError(
        'DAP launch requires the Flutter frontend_server artifacts needed '
        'for hot reload.',
      );
    }

    final mode = hotReload != null
        ? 'debug/JIT, hot reload'
        : 'debug/JIT, attached via CoreDevice';
    runtime.log.logInfo('App', '${pack.bundleId} ${runtime.log.dim(mode)}');

    final operation = await DeviceRunOperation.resolve(
      pymd,
      sockets: sockets,
      httpClients: runtime.signingHttpClients,
      connector: runtime.vmConnector,
      vmOutput: runtime.vmOutput,
      hostServices: runtime.appleHostServices,
      createNativeLibraryLoader: runtime.createNativeLibraryLoader,
    );
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
