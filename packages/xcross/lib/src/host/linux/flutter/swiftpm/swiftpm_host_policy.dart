import 'package:xcross/src/flutter/build/ios_linker_compatibility.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_swiftpm_host_policy.dart';

final class LinuxSwiftPmHostPolicy extends PosixSwiftPmHostPolicy {
  const LinuxSwiftPmHostPolicy();
  @override
  List<String> get fingerprintArguments =>
      objectiveCSmallStubSwiftDriverArguments;
}
