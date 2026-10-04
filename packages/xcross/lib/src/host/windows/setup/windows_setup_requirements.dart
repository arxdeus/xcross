import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:darwin_sdk_kit/shared/toolchain/darwin_toolchain_resolver.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/cli/basic/internal/clang_requirement.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/setup/setup_requirements.dart';

@internal
final class WindowsSetupRequirements implements SetupRequirements {
  WindowsSetupRequirements(this.services);
  final SetupRequirementServices services;
  PlatformHostInterface get host => services.host;
  ProcessRunner get runner => services.runner;
  DarwinToolchainResolver get toolchain => services.toolchain;

  @override
  Future<void> run() async {
    final missing = await services.missingTools([
      'flutter',
      'swift',
      'llvm-ar',
      'ld64.lld',
    ]);
    if (missing.isNotEmpty) {
      throw XcrossError(
        'Missing Windows requirements on PATH: ${missing.join(', ')}.\n'
        'Install Flutter, Swift, and the official LLVM Windows toolchain, '
        'then retry.',
      );
    }
    if (await ClangRequirement(
          runner,
        ).resolve(llvmDirectories: toolchain.llvmToolDirs()) ==
        null) {
      throw XcrossError(
        'Clang 20 or newer (clang and clang++) is required on Windows. '
        'Install the official LLVM Windows toolchain from https://llvm.org, '
        'add its bin directory to PATH, and retry `xcross setup`.',
      );
    }
    await services.ensurePymd();
    runner.log.logDone('Windows requirements found');
  }
}
