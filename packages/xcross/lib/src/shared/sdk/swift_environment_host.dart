import 'package:meta/meta.dart';
import 'package:xcross/src/shared/cli/basic/doctor_models.dart';

@internal
abstract interface class SwiftEnvironmentHostInterface {
  Future<Map<String, String>> swiftEnvironment();
  Future<List<DoctorCheck>> doctorChecks();
}
