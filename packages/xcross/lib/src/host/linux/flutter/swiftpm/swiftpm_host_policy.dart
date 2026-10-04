import 'package:xcross/src/host/shared/flutter/swiftpm/posix_swiftpm_host_policy.dart';
import 'package:xcross/src/shared/flutter/build/ios_linker_compatibility.dart';

final class LinuxSwiftPmHostPolicy extends PosixSwiftPmHostPolicy {
  const LinuxSwiftPmHostPolicy();
  @override
  List<String> get fingerprintArguments =>
      objectiveCSmallStubSwiftDriverArguments;
}
