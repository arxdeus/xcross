import 'package:args/command_runner.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:dart_mobile_device/shared/network/device_sockets.dart';
import 'package:dart_mobile_device/target/iphone/device/pymd/pymd.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/composition/cli/compose_build_command.dart';
import 'package:xcross/src/composition/cli/compose_run_command.dart';
import 'package:xcross/src/composition/cli/compose_setup_command.dart';
import 'package:xcross/src/shared/cli/compose/compose_clean_command.dart';
import 'package:xcross/src/shared/runtime/xcross_runtime.dart';

@internal
final class ComposeCommand<T extends PlatformHostInterface>
    extends Command<void> {
  ComposeCommand(
    XcrossRuntime<T> runtime,
    Pymd pymd,
    DeviceSockets sockets, {
    ComposeBuildCommand? buildCommand,
    ComposeRunCommand? runCommand,
    ComposeSetupCommand? setupCommand,
    Command<void>? doctorCommand,
  }) {
    addSubcommand(buildCommand ?? ComposeBuildCommand(runtime));
    addSubcommand(
      runCommand ?? ComposeRunCommand(runtime, pymd, sockets: sockets),
    );
    addSubcommand(setupCommand ?? ComposeSetupCommand(runtime));
    addSubcommand(
      ComposeCleanCommand(
        host: runtime.host,
        log: runtime.log,
        projectRoot: runtime.host.paths.context.current,
      ),
    );
    if (doctorCommand != null) addSubcommand(doctorCommand);
  }

  @override
  String get name => 'compose';

  @override
  String get description =>
      'Build, run, and diagnose Compose Multiplatform iOS apps without Xcode.';
}
