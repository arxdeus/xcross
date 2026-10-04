import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:darwin_sdk_kit/shared/toolchain/darwin_toolchain_resolver.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/setup/setup_requirements.dart';

@internal
final class MacOSSetupRequirements implements SetupRequirements {
  MacOSSetupRequirements(this.services);
  final SetupRequirementServices services;
  PlatformHostInterface get host => services.host;
  ProcessRunner get runner => services.runner;
  DarwinToolchainResolver get toolchain => services.toolchain;
  static const _requiredTools = [
    'swift',
    'clang',
    'clang++',
    'llvm-ar',
    'ld64.lld',
  ];

  @override
  Future<void> run() async {
    if (await runner.which('brew') == null) {
      throw XcrossError(
        'Homebrew is required for `xcross setup` on macOS.\n'
        'Install it from https://brew.sh and retry.',
      );
    }

    await brewInstall(const ['lld', 'llvm']);

    final missing = await services.missingTools(_requiredTools);
    if (missing.isNotEmpty) {
      throw XcrossError(
        'Missing macOS requirements after Homebrew install: '
        '${missing.join(', ')}.\n'
        'Install the Swift toolchain manually and ensure its bin directory is '
        'on PATH. LLVM tools come from `brew install lld llvm`.',
      );
    }

    final pipx = await services.ensurePipx(
      attempts: await pipxInstallAttemptsMacos(),
      manualHint: 'Install manually:\n    brew install pipx',
    );
    await services.ensurePymd();
    await services.pipxEnsurePath(pipx);
    runner.log.logDone('Requirements installed');
  }

  Future<void> brewInstall(List<String> packages) async {
    final step = runner.log.beginStep('Installing Homebrew requirements');
    try {
      await runner.runChecked(
        'brew',
        ['install', ...packages],
        label: 'brew install',
        tail: step,
      );
      step.done();
    } on Object {
      step.fail();
      rethrow;
    }
  }

  Future<List<List<String>>> pipxInstallAttemptsMacos() async {
    final py = await runner.which('python3') ?? 'python3';
    return <List<String>>[
      ['brew', 'install', 'pipx'],
      [py, '-m', 'pip', 'install', '--user', '--break-system-packages', 'pipx'],
      [py, '-m', 'pip', 'install', '--user', 'pipx'],
    ];
  }
}
