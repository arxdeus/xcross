import 'package:args/command_runner.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:dart_mobile_device/shared/network/device_sockets.dart';
import 'package:dart_mobile_device/target/iphone/device/pymd/pymd.dart';
import 'package:dart_mobile_device/target/iphone/tunnel/pymd_tunnel_availability.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/composition/cli/flutter_build_command.dart';
import 'package:xcross/src/composition/cli/flutter_run_command.dart';
import 'package:xcross/src/composition/ios_target.dart';
import 'package:xcross/src/shared/cli/flutter/subcommands/dap_command.dart';
import 'package:xcross/src/shared/cli/flutter/subcommands/flutter_clean_command.dart';
import 'package:xcross/src/shared/runtime/xcross_runtime.dart';

/// `xcross flutter` — parent command grouping `build`, `run`, `clean`, and
/// hidden `dap`.
@internal
final class FlutterCommand<T extends PlatformHostInterface>
    extends Command<void> {
  FlutterCommand(XcrossRuntime<T> runtime, Pymd pymd, DeviceSockets sockets) {
    addSubcommand(FlutterBuildCommand(runtime));
    addSubcommand(FlutterRunCommand(runtime, pymd, sockets: sockets));
    addSubcommand(
      FlutterCleanCommand(
        log: runtime.log,
        projectRoot: runtime.host.paths.context.current,
        policies: composeFlutterTargetPolicies(runtime.host),
        environment: runtime.runner.effectiveEnvironment,
      ),
    );
    addSubcommand(
      DapCommand(
        runtime,
        tunnelAvailability: PymdTunnelAvailability(
          localHttp: runtime.localHttp,
        ),
      ),
    );
  }

  @override
  String get name => 'flutter';

  @override
  String get description => 'Build and run Flutter iOS apps without Xcode.';
}
