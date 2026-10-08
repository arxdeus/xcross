import 'package:meta/meta.dart';
import 'package:xcross/src/shared/cli/basic/doctor_models.dart';
import 'package:xcross/src/shared/sdk/swift_environment_host.dart';

@internal
final class InheritedSwiftEnvironment implements SwiftEnvironmentHostInterface {
  const InheritedSwiftEnvironment();

  @override
  Future<Map<String, String>> swiftEnvironment() async => const {};

  @override
  Future<List<DoctorCheck>> doctorChecks() async => const [];
}
