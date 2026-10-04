import 'package:xcross/src/shared/cli/basic/doctor_environment_checks.dart';
import 'package:xcross/src/shared/cli/basic/doctor_models.dart';
import 'package:xcross/src/shared/diagnostics/doctor_project_inspector.dart';

typedef DoctorChecks = Future<List<DoctorCheck>> Function();
typedef DoctorDetectProject = Future<DoctorProject?> Function();
typedef DoctorProjectCheckRunner =
    Future<List<DoctorCheck>> Function(DoctorProject project);

final class DoctorExaminer {
  DoctorExaminer({
    required String projectRoot,
    required DoctorEnvironmentChecks environmentChecks,
    required DoctorProjectInspector projectChecks,
  }) : this.withSeams(
         hostChecks: environmentChecks.host,
         detectProject: () async => projectChecks.detect(projectRoot),
         projectChecks: projectChecks.examine,
         runChecks: environmentChecks.run,
       );

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
}
