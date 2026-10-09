@internal
library;

import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:dart_mobile_device/shared/device/models/device.dart';
import 'package:dart_mobile_device/shared/network/device_sockets.dart';
import 'package:dart_mobile_device/target/iphone/device/pymd/pymd.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/composition/cli/flutter_build_command.dart';
import 'package:xcross/src/composition/ios_target.dart';
import 'package:xcross/src/shared/cli/device_selection.dart';
import 'package:xcross/src/shared/cli/internal/parsed_command.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/flutter/build/flutter_pack_operation.dart';
import 'package:xcross/src/shared/flutter/build/hot_reload_setup.dart';
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_options.dart';
import 'package:xcross/src/shared/models/pack_result.dart';
import 'package:xcross/src/shared/runtime/xcross_runtime.dart';
import 'package:xcross/src/target/iphone/device/core_device_launch_profile.dart';
import 'package:xcross/src/target/iphone/device/device_run_operation.dart';
import 'package:xcross/src/target/shared/runtime/build_features.dart';

part 'flutter_run_command.g.dart';

@internal
typedef FlutterRunPack =
    Future<PackResult> Function(FlutterBuildOptions options);

@internal
typedef FlutterRunDevice =
    Future<void> Function({
      required PackResult pack,
      required String? selector,
      required DeviceSearchMode mode,
      required CoreDeviceLaunchProfile launchProfile,
    });

/// Options for `xcross flutter run`.
@internal
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

  @CliOption(negatable: false, help: 'Run a debug (JIT) build (default).')
  late bool debug;

  @CliOption(
    negatable: false,
    help: 'Run an ahead-of-time compiled profile build, without hot reload.',
  )
  late bool profile;

  @CliOption(
    negatable: false,
    help: 'Run an ahead-of-time compiled release build, without hot reload.',
  )
  late bool release;
}

/// `xcross flutter run` — build, sign, install, launch, and hot-reload a
/// Flutter app on a connected iOS 17+ device.
///
/// Debug builds (the default) launch with hot reload; `--profile` and
/// `--release` run ahead-of-time compiled code without it.
@internal
final class FlutterRunCommand<T extends PlatformHostInterface>
    extends ParsedCommand<FlutterRunArgs, void> {
  FlutterRunCommand(this.runtime, this.pymd, {required this.sockets})
    : features = composePhysicalFeatures(runtime),
      _packOverride = null,
      _runDeviceOverride = null;

  /// Replaces the build and the device run, so tests can observe what the
  /// command hands to each without a Flutter SDK or a device.
  @visibleForTesting
  FlutterRunCommand.withSeams(
    this.runtime,
    this.pymd, {
    required this.sockets,
    required FlutterRunPack pack,
    required FlutterRunDevice runDevice,
  }) : features = composePhysicalFeatures(runtime),
       _packOverride = pack,
       _runDeviceOverride = runDevice;
  @override
  ArgParser populateOptions(ArgParser parser) =>
      _$populateFlutterRunArgsParser(parser);
  @override
  FlutterRunArgs parseOptions(ArgResults results) =>
      _$parseFlutterRunArgsResult(results);

  final XcrossBuildFeatures<T> features;

  final XcrossRuntime<T> runtime;
  final Pymd pymd;
  final DeviceSockets sockets;
  final FlutterRunPack? _packOverride;
  final FlutterRunDevice? _runDeviceOverride;
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

  Future<PackResult> _pack(FlutterBuildOptions buildOptions) =>
      _packOverride?.call(buildOptions) ??
      FlutterPackOperation.pack(
        projectRoot: runtime.host.paths.context.current,
        runtime: features.flutterRuntime,
        options: buildOptions,
      );

  Future<void> _runDevice({
    required PackResult pack,
    required CoreDeviceLaunchProfile launchProfile,
  }) => (_runDeviceOverride ?? _runOnDevice)(
    pack: pack,
    selector: _deviceSelector,
    mode: _searchMode,
    launchProfile: launchProfile,
  );

  Future<void> _runOnDevice({
    required PackResult pack,
    required String? selector,
    required DeviceSearchMode mode,
    required CoreDeviceLaunchProfile launchProfile,
  }) async {
    final operation = await DeviceRunOperation.resolve(
      pymd,
      sockets: sockets,
      httpClients: runtime.signingHttpClients,
      connector: runtime.vmConnector,
      vmOutput: runtime.vmOutput,
      hostServices: runtime.appleHostServices,
      createNativeLibraryLoader: runtime.createNativeLibraryLoader,
      prompt: runtime.commandPrompt,
    );
    await operation.run(
      pack: pack,
      selector: selector,
      mode: mode,
      launchProfile: launchProfile,
    );
  }

  @override
  Future<void> run() async {
    if (options.verbose) runtime.log.setVerbose();

    final buildMode = flutterBuildModeOf(
      debug: options.debug,
      profile: options.profile,
      release: options.release,
      usageException: usageException,
    );
    final buildRuntime = features.flutterRuntime;
    final buildOptions = await buildRuntime.options.resolve(
      target: options.target,
      dartDefine: options.dartDefine,
      dartDefineFromFile: options.dartDefineFromFile,
      pub: options.pub,
      flavor: options.flavor,
      buildMode: buildMode,
    );
    final pack = await _pack(buildOptions);

    final hotReload = buildMode.isPrecompiled
        ? null
        : await HotReloadSetup.buildHotReloadConfig(
            projectRoot: runtime.host.paths.context.current,
            runtime: buildRuntime,
            target: buildOptions.target,
            dartDefines: pack.dartDefines,
            verbose: options.verbose,
          );
    if (hotReload == null &&
        runtime.runner.effectiveEnvironment['XCROSS_DAP'] == '1') {
      throw XcrossError(
        buildMode.isPrecompiled
            ? 'DAP launch requires a debug build.'
            : 'DAP launch requires the Flutter frontend_server artifacts '
                  'needed for hot reload.',
      );
    }

    final mode = buildMode.isPrecompiled
        ? '${buildMode.name}/AOT'
        : hotReload != null
        ? 'debug/JIT, hot reload'
        : 'debug/JIT, attached via CoreDevice';
    runtime.log.logInfo('App', '${pack.bundleId} ${runtime.log.dim(mode)}');

    await _runDevice(
      pack: pack,
      launchProfile: CoreDeviceLaunchProfile.flutter(
        buildMode: buildMode,
        arguments: _appArguments,
        hotReload: hotReload,
      ),
    );
  }
}
