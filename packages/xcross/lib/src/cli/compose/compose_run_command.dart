import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:cli_kit/cli_kit_shared.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:xcross/src/cli/compose/compose_build_command.dart';
import 'package:xcross/src/cli/internal/parsed_command.dart';
import 'package:xcross/src/cli/shared/device_selection.dart';
import 'package:xcross/src/compose/models/compose_build_options.dart';
import 'package:xcross/src/compose/watch/compose_watch_session.dart';
import 'package:xcross/src/compose/watch/kotlin_source_watcher.dart';
import 'package:xcross/src/composition/ios_target.dart';
import 'package:xcross/src/device/core_device_launch_profile.dart';
import 'package:xcross/src/device/device_run_operation.dart';
import 'package:xcross/src/models/pack_result.dart';
import 'package:xcross/src/shared/runtime/xcross_runtime.dart';
import 'package:xcross/src/target/shared/runtime/build_features.dart';

part 'compose_run_command.g.dart';

typedef ComposeRunDevice =
    Future<void> Function({
      required PackResult pack,
      required String? selector,
      required DeviceSearchMode mode,
      required CoreDeviceLaunchProfile launchProfile,
      Future<bool> Function()? onRestartRequested,
    });

@CliOptions()
final class ComposeRunArgs {
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

  @CliOption(
    help:
        'Override CFBundleIdentifier. An App ID your team already owns is '
        'signed as-is, keeping Sign in with Apple, passkeys and push.',
  )
  late String? bundleId;

  @CliOption(abbr: 'a', help: 'Pass arguments to the app main() (repeatable).')
  late List<String> appArgument;

  @CliOption(
    help:
        'Watch Kotlin sources and rebuild, reinstall, and relaunch on "r". '
        'Kotlin/Native is AOT-compiled, so this is a fast restart, not an '
        'in-place hot reload.',
    negatable: false,
  )
  late bool watch;

  @CliOption(abbr: 'v', help: 'Verbose output.', negatable: false)
  late bool verbose;
}

final class ComposeRunCommand<T extends PlatformHostInterface>
    extends ParsedCommand<ComposeRunArgs, void> {
  @override
  ArgParser populateOptions(ArgParser parser) =>
      _$populateComposeRunArgsParser(parser);
  @override
  ComposeRunArgs parseOptions(ArgResults results) =>
      _$parseComposeRunArgsResult(results);

  ComposeRunCommand(XcrossRuntime<T> runtime)
    : this._withRuntime(runtime, composePhysicalFeatures(runtime));

  ComposeRunCommand._withRuntime(
    XcrossRuntime<T> runtime,
    XcrossBuildFeatures<T> features,
  ) : this.withSeams(
        log: runtime.log,
        files: runtime.host.fileSystem,
        projectRoot: runtime.host.paths.context.current,
        packOperation:
            ({
              required options,
              required requireRunnableApp,
              required targetPlatform,
            }) => features.composeOperation.pack(
              options: options,
              requireRunnableApp: requireRunnableApp,
            ),
        runDevice:
            ({
              required pack,
              required selector,
              required mode,
              required launchProfile,
              onRestartRequested,
            }) async {
              final operation = await DeviceRunOperation.resolve(
                runtime.pymd,
                httpClients: runtime.signingHttpClients,
                connector: runtime.vmConnector,
                vmOutput: runtime.vmOutput,
                hostServices: runtime.appleHostServices,
                createNativeLibraryLoader: runtime.createNativeLibraryLoader,
              );
              await operation.run(
                pack: pack,
                selector: selector,
                mode: mode,
                launchProfile: launchProfile,
                onRestartRequested: onRestartRequested,
              );
            },
      );

  ComposeRunCommand.withSeams({
    required this.log,
    required this.files,
    required this.projectRoot,
    required ComposeCliPackOperation packOperation,
    required ComposeRunDevice runDevice,
  }) : _packOperation = packOperation,
       _runDevice = runDevice;

  final HostFileSystemInterface files;
  final String projectRoot;
  final Log log;
  final ComposeCliPackOperation _packOperation;
  final ComposeRunDevice _runDevice;

  @override
  String get name => 'run';

  @override
  String get description =>
      'Build, install, and run a Compose Multiplatform iOS app on a device.';

  String? get _deviceSelector => options.udid ?? options.deviceId;

  DeviceSearchMode get _searchMode => deviceSearchMode(
    usb: options.usb,
    wifi: options.wifi,
    deviceConnection: options.deviceConnection,
  );

  @override
  Future<void> run() async {
    if (options.verbose) log.setVerbose();
    final pack = await _packOperation(
      options: ComposeBuildOptions(bundleId: options.bundleId),
      requireRunnableApp: true,
      targetPlatform: 'iphone',
    );
    log.logInfo(
      'App',
      '${pack.bundleId} ${log.dim('native, attached via CoreDevice')}',
    );
    final profile = CoreDeviceLaunchProfile.native(
      arguments: options.appArgument,
    );
    if (!options.watch) {
      await _runDevice(
        pack: pack,
        selector: _deviceSelector,
        mode: _searchMode,
        launchProfile: profile,
      );
      return;
    }

    log.logInfo(
      'Watching',
      'Kotlin sources '
          '${log.dim('press r to rebuild and restart, q to quit')}',
    );
    final session = ComposeWatchSession(
      log: log,
      watcher: KotlinSourceWatcher(
        pack.projectRoot ?? projectRoot,
        files: files,
      ),
      rebuild: () => _packOperation(
        options: ComposeBuildOptions(bundleId: options.bundleId),
        requireRunnableApp: true,
        targetPlatform: 'iphone',
      ),
      runSession: ({required pack, required onRestartRequested}) => _runDevice(
        pack: pack,
        selector: _deviceSelector,
        mode: _searchMode,
        launchProfile: profile,
        onRestartRequested: onRestartRequested,
      ),
    );
    await session.run(pack);
  }
}
