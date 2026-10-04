import 'package:meta/meta.dart';
import 'package:xcross/src/shared/sdk/swift_toolchain_host.dart';

@internal
final class MacOSSwiftToolchainHost implements SwiftToolchainHostInterface {
  const MacOSSwiftToolchainHost();

  @override
  String get installGuidance =>
      'Install Swift with Xcode or the toolchain installer from\n'
      'https://www.swift.org/install/macos/';

  @override
  String? failureGuidance(int exitCode) => null;
}
