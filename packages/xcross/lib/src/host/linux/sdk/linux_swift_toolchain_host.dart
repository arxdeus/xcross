import 'package:meta/meta.dart';
import 'package:xcross/src/shared/sdk/swift_toolchain_host.dart';

@internal
final class LinuxSwiftToolchainHost implements SwiftToolchainHostInterface {
  const LinuxSwiftToolchainHost();

  @override
  String get installGuidance =>
      'Install Swift from https://www.swift.org/install/linux/ (swiftly is the\n'
      'easiest route), then open a new terminal so its bin directory is on '
      'PATH.';

  @override
  String? failureGuidance(int exitCode) => null;
}
