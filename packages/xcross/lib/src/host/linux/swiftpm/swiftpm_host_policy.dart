import 'package:meta/meta.dart';
import 'package:xcross/src/host/shared/swiftpm/posix_swiftpm_host_policy.dart';
import 'package:xcross/src/shared/swiftpm/ios_linker_compatibility.dart';

@internal
final class LinuxSwiftPmHostPolicy extends PosixSwiftPmHostPolicy {
  const LinuxSwiftPmHostPolicy();
  @override
  List<String> get fingerprintArguments =>
      objectiveCSmallStubSwiftDriverArguments;
}
