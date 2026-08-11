import 'package:args/command_runner.dart';
import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:xcross/src/cli/compose/compose_build_command.dart';
import 'package:xcross/src/cli/shared/device_selection.dart';
import 'package:xcross/src/compose/build/compose_pack_operation.dart';
import 'package:xcross/src/compose/models/compose_build_options.dart';
import 'package:xcross/src/device/core_device_launch_profile.dart';
import 'package:xcross/src/device/device_run_operation.dart';
import 'package:xcross/src/models/pack_result.dart';

part 'compose_run_command.g.dart';

typedef ComposeRunDevice =
    Future<void> Function({
      required PackResult pack,
      required String? selector,
      required DeviceSearchMode mode,
      required CoreDeviceLaunchProfile launchProfile,
    });

@CliOptions(createCommand: true)
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

  @CliOption(abbr: 'a', help: 'Pass arguments to the app main() (repeatable).')
  late List<String> appArgument;

  @CliOption(abbr: 'v', help: 'Verbose output.', negatable: false)
  late bool verbose;
}

final class ComposeRunCommand extends _$ComposeRunArgsCommand<void> {
  ComposeRunCommand()
    : this.withSeams(
        packOperation: _defaultRunPackOperation,
        runDevice: _defaultRunDevice,
      );

  ComposeRunCommand.withSeams({
    required ComposeCliPackOperation packOperation,
    required ComposeRunDevice runDevice,
  }) : _packOperation = packOperation,
       _runDevice = runDevice;

  final ComposeCliPackOperation _packOperation;
  final ComposeRunDevice _runDevice;

  @override
  String get name => 'run';

  @override
  String get description =>
      'Build, install, and run a Compose Multiplatform iOS app on a device.';

  String? get _deviceSelector => _options.udid ?? _options.deviceId;

  DeviceSearchMode get _searchMode => deviceSearchMode(
    usb: _options.usb,
    wifi: _options.wifi,
    deviceConnection: _options.deviceConnection,
  );

  @override
  Future<void> run() async {
    if (_options.verbose) Log.setVerbose();
    final pack = await _packOperation(
      options: const ComposeBuildOptions(),
      requireRunnableApp: true,
    );
    Log.logInfo(
      'App',
      '${pack.bundleId} ${Log.ansi.subtle('native, attached via CoreDevice')}',
    );
    await _runDevice(
      pack: pack,
      selector: _deviceSelector,
      mode: _searchMode,
      launchProfile: CoreDeviceLaunchProfile.native(
        arguments: _options.appArgument,
      ),
    );
  }

  static Future<void> _defaultRunDevice({
    required PackResult pack,
    required String? selector,
    required DeviceSearchMode mode,
    required CoreDeviceLaunchProfile launchProfile,
  }) async {
    final operation = await DeviceRunOperation.resolve();
    await operation.run(
      pack: pack,
      selector: selector,
      mode: mode,
      launchProfile: launchProfile,
    );
  }
}

Future<PackResult> _defaultRunPackOperation({
  required ComposeBuildOptions options,
  required bool requireRunnableApp,
}) => ComposePackOperation.pack(
  options: options,
  requireRunnableApp: requireRunnableApp,
);
