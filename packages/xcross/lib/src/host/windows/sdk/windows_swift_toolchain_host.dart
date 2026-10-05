import 'package:meta/meta.dart';
import 'package:xcross/src/shared/sdk/swift_toolchain_host.dart';

@internal
final class WindowsSwiftToolchainHost implements SwiftToolchainHostInterface {
  const WindowsSwiftToolchainHost();

  static const _statusDllNotFound = 0xC0000135;

  @override
  (int, int)? get minimumSwift => (6, 4);

  @override
  String get installGuidance =>
      'Install Swift for Windows from https://www.swift.org/install/windows/\n'
      'then open a new terminal so its bin directory is on PATH.';

  @override
  String? failureGuidance(int exitCode) {
    if (exitCode != _statusDllNotFound &&
        exitCode != _statusDllNotFound - 0x100000000) {
      return null;
    }
    return 'The Swift toolchain binaries cannot start because their runtime DLLs '
        'are not on PATH. Open a new terminal so the installer PATH applies, '
        r'or add %LOCALAPPDATA%\Programs\Swift\Runtimes\<version>\usr\bin to '
        'PATH.';
  }
}
