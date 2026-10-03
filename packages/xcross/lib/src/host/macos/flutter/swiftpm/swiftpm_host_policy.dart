import 'package:xcross/src/flutter/build/macho_dylib_rewriter.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_swiftpm_host_policy.dart';

final class MacOSSwiftPmHostPolicy extends PosixSwiftPmHostPolicy {
  const MacOSSwiftPmHostPolicy();
  @override
  Future<void> rewriteDylib(String path, Set<String> names) =>
      MachODylibRewriter.rewriteFile(path, producedDylibNames: names);
}
