import 'dart:io';

import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:xcross/src/cli/basic/doctor_environment_checks.dart';
import 'package:xcross/src/cli/basic/doctor_models.dart';
import 'package:xcross/src/cli/basic/doctor_project_checks.dart';

typedef DoctorChecks = Future<List<DoctorCheck>> Function();
typedef DoctorDetectProject = Future<DoctorProject?> Function();
typedef DoctorProjectCheckRunner =
    Future<List<DoctorCheck>> Function(DoctorProject project);

final class DoctorExaminer {
  const DoctorExaminer()
    : _hostChecks = DoctorEnvironmentChecks.host,
      _detectProject = _detectCurrentProject,
      _projectChecks = DoctorProjectChecks.examine,
      _runChecks = DoctorEnvironmentChecks.run;

  const DoctorExaminer.withSeams({
    required DoctorChecks hostChecks,
    required DoctorDetectProject detectProject,
    required DoctorProjectCheckRunner projectChecks,
    required DoctorChecks runChecks,
  }) : _hostChecks = hostChecks,
       _detectProject = detectProject,
       _projectChecks = projectChecks,
       _runChecks = runChecks;

  final DoctorChecks _hostChecks;
  final DoctorDetectProject _detectProject;
  final DoctorProjectCheckRunner _projectChecks;
  final DoctorChecks _runChecks;

  Future<List<DoctorCheck>> examine() async {
    final checks = [...await _hostChecks()];
    final project = await _detectProject();
    checks.addAll(
      project == null
          ? const [
              DoctorCheck.warning(
                'Project',
                'No Flutter or Compose project found in the current directory.',
              ),
            ]
          : await _projectChecks(project),
    );
    checks.addAll(await _runChecks());
    return checks;
  }

  static Future<DoctorProject?> _detectCurrentProject() async =>
      detectProjectAt(Directory.current.path);

  static DoctorProject? detectProjectAt(String root) =>
      DoctorProjectChecks.detect(root);

  static Future<List<DoctorCheck>> deviceChecks(
    List<Device> devices, {
    Future<int?> Function(Device device)? osMajorVersion,
  }) =>
      DoctorEnvironmentChecks.devices(devices, osMajorVersion: osMajorVersion);
}
