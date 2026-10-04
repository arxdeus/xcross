import 'package:xcross/src/shared/cli/basic/doctor_models.dart';

abstract interface class DoctorProjectInspector {
  DoctorProject? detect(String root);
  Future<List<DoctorCheck>> examine(DoctorProject project);
}
