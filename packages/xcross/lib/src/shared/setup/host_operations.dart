import 'package:xcross/src/shared/setup/setup_requirements.dart';
import 'package:xcross/src/shared/setup/setup_script_policy.dart';
import 'package:xcross/src/shared/update/update_host_policy.dart';

final class HostOperations {
  const HostOperations({
    required this.setupScript,
    required this.setupRequirements,
    required this.swiftInstallGuidance,
    required this.update,
    required this.normalizeExecutable,
    required this.acceptDartLauncher,
  });
  final SetupScriptPolicy setupScript;
  final SetupRequirements setupRequirements;
  final String swiftInstallGuidance;
  final UpdateHostPolicy update;
  final String Function(String) normalizeExecutable;
  final bool Function(String) acceptDartLauncher;
}
