import 'package:meta/meta.dart';
import 'package:xcross/src/shared/sdk/swift_environment_host.dart';
import 'package:xcross/src/shared/sdk/swift_toolchain_host.dart';
import 'package:xcross/src/shared/setup/setup_requirements.dart';
import 'package:xcross/src/shared/setup/setup_script_policy.dart';
import 'package:xcross/src/shared/update/update_host_policy.dart';

@internal
final class HostOperations {
  const HostOperations({
    required this.setupScript,
    required this.setupRequirements,
    required this.swiftToolchain,
    required this.swiftEnvironment,
    required this.update,
    required this.normalizeExecutable,
    required this.acceptDartLauncher,
  });
  final SetupScriptPolicy setupScript;
  final SetupRequirements setupRequirements;
  final SwiftToolchainHostInterface swiftToolchain;
  final SwiftEnvironmentHostInterface swiftEnvironment;
  String get swiftInstallGuidance => swiftToolchain.installGuidance;
  (int, int)? get minimumSwift => swiftToolchain.minimumSwift;
  final UpdateHostPolicy update;
  final String Function(String) normalizeExecutable;
  final bool Function(String) acceptDartLauncher;
}
