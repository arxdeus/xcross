import 'package:cli_kit/shared/download/download.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk_repository.dart';
import 'package:darwin_sdk_kit/shared/toolchain/darwin_toolchain_resolver.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/compose/compose_build_context.dart';
import 'package:xcross/src/shared/compose/compose_host.dart';
import 'package:xcross/src/shared/compose/compose_java_resolver.dart';
import 'package:xcross/src/shared/compose/compose_process_contracts.dart';
import 'package:xcross/src/shared/compose/compose_setup_options.dart';
import 'package:xcross/src/shared/compose/toolchain/compose_toolchain.dart';
import 'package:xcross/src/shared/compose/toolchain/compose_toolchain_installer.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/target/shared/compose/compose_target.dart';

@internal
final class ComposeToolchainResolver<T extends PlatformHostInterface> {
  factory ComposeToolchainResolver(
    ComposeTarget<T> target, {
    required ProcessRunner<T> runner,
    required Log log,
    required Downloader downloader,
    required DarwinToolchainResolver<T> tools,
    required DarwinSdkRepository<T> sdkRepository,
    String? cacheRoot,
  }) {
    final context = ComposeBuildContext(
      target: target,
      runner: runner,
      tools: tools,
      sdkRepository: sdkRepository,
      log: log,
      downloader: downloader,
      cacheRoot: cacheRoot,
    );
    final selectedRunner = context.runner;
    return ComposeToolchainResolver.withSeams(
      target,
      runner: selectedRunner,
      log: log,
      downloader: downloader,
      cacheRoot: cacheRoot,
      which: selectedRunner.which,
      run: (executable, arguments, {workingDirectory, environment}) async {
        final result = await selectedRunner.run(
          executable,
          arguments,
          workingDirectory: workingDirectory,
          environment: environment,
        );
        return ComposeProcessResult(
          result.exitCode,
          result.stdout,
          result.stderr,
        );
      },
      currentDarwinSdk: (_) {
        final repository = sdkRepository;
        final sdk = repository.current();
        return sdk == null ? null : RepositoryComposeDarwinSdk(sdk, repository);
      },
      resolveLd64Lld: (_) => tools.resolveLd64Lld(),
      installer: ComposeToolchainInstaller(selectedRunner, downloader),
    );
  }
  factory ComposeToolchainResolver.withSeams(
    ComposeTarget<T> target, {
    required Log log,
    required Downloader downloader,
    required ProcessRunner<T> runner,
    DarwinSdkRepository<T>? sdkRepository,
    String? cacheRoot,
    ComposeWhich? which,
    ComposeRun? run,
    CurrentDarwinSdk? currentDarwinSdk,
    ResolveLd64Lld? resolveLd64Lld,
    ComposeToolchainInstaller<T>? installer,
  }) {
    final selectedRunner = runner;
    if (!identical(target.host, runner.host) ||
        !identical(log, runner.log) ||
        !identical(log, downloader.log)) {
      throw ArgumentError(
        'Compose resolver effects must share the injected host and logger.',
      );
    }
    if (sdkRepository != null &&
        (!identical(sdkRepository.host, target.host) ||
            !identical(sdkRepository.log, log))) {
      throw ArgumentError(
        'Compose SDK repository must share the injected host and logger.',
      );
    }
    return ComposeToolchainResolver._(
      target,
      runner: selectedRunner,
      log: log,
      cacheRoot: cacheRoot,
      which: which ?? selectedRunner.which,
      run:
          run ??
          ((executable, arguments, {workingDirectory, environment}) async {
            final result = await selectedRunner.run(
              executable,
              arguments,
              workingDirectory: workingDirectory,
              environment: environment,
            );
            return ComposeProcessResult(
              result.exitCode,
              result.stdout,
              result.stderr,
            );
          }),
      currentDarwinSdk:
          currentDarwinSdk ??
          ((_) {
            if (sdkRepository == null) {
              throw XcrossError('Missing injected Darwin SDK repository.');
            }
            final sdk = sdkRepository.current();
            return sdk == null
                ? null
                : RepositoryComposeDarwinSdk(sdk, sdkRepository);
          }),
      resolveLd64Lld:
          resolveLd64Lld ??
          ((_) async =>
              throw XcrossError('Missing injected Darwin tool resolver.')),
      installer:
          installer ?? ComposeToolchainInstaller(selectedRunner, downloader),
    );
  }
  ComposeToolchainResolver._(
    this.target, {
    required this.log,
    required ComposeWhich which,
    required ComposeRun run,
    required CurrentDarwinSdk currentDarwinSdk,
    required ResolveLd64Lld resolveLd64Lld,
    required ComposeToolchainInstaller<T> installer,
    required this.runner,
    this.cacheRoot,
  }) : _which = which,
       _run = run,
       _currentDarwinSdk = currentDarwinSdk,
       _resolveLd64Lld = resolveLd64Lld,
       _installer = installer;

  final ComposeWhich _which;
  final ComposeRun _run;
  final CurrentDarwinSdk _currentDarwinSdk;
  final ResolveLd64Lld _resolveLd64Lld;
  final ComposeToolchainInstaller<T> _installer;
  final ComposeTarget<T> target;
  final ProcessRunner<T> runner;
  final Log log;
  final String? cacheRoot;

  Future<ComposeToolchain<T>?> resolve({
    required Map<String, String> environment,
    required String projectRoot,
  }) async {
    final options = ComposeSetupOptions.resolve(
      cacheRootOverride: cacheRoot,
      env: environment,
      projectRoot: projectRoot,
      host: target.toolchainHost,
    );
    final found = await _resolved(
      environment: environment,
      projectRoot: projectRoot,
      options: options,
    );
    return found.problems.isEmpty ? found.toolchain : null;
  }

  Future<List<String>> problems({
    required Map<String, String> environment,
    required String projectRoot,
  }) async {
    final options = ComposeSetupOptions.resolve(
      cacheRootOverride: cacheRoot,
      env: environment,
      projectRoot: projectRoot,
      host: target.toolchainHost,
    );
    final found = await _resolved(
      environment: environment,
      projectRoot: projectRoot,
      options: options,
    );
    return found.problems;
  }

  Future<ComposeToolchain<T>> ensure({
    required Map<String, String> environment,
    required String projectRoot,
    bool allowInstall = true,
    bool force = false,
  }) async {
    final options = ComposeSetupOptions.resolve(
      cacheRootOverride: cacheRoot,
      env: environment,
      projectRoot: projectRoot,
      host: target.toolchainHost,
    );
    final found = await _resolved(
      environment: environment,
      projectRoot: projectRoot,
      options: options,
    );
    if (found.toolchain != null && !force) return found.toolchain!;
    final kotlinProblem = found.problems.firstWhere(
      (problem) => problem.contains('Kotlin/Native compiler'),
      orElse: () => '',
    );
    final nonKotlinProblems = found.problems
        .where((problem) => !problem.contains('Kotlin/Native compiler'))
        .toList();
    if (nonKotlinProblems.isNotEmpty) {
      throw XcrossError(nonKotlinProblems.join('\n'));
    }
    if (!allowInstall) {
      throw XcrossError(found.problems.join('\n'));
    }
    if (kotlinProblem.isEmpty && !force) {
      throw XcrossError(found.problems.join('\n'));
    }
    await _installer.install(
      options: options,
      force:
          force ||
          runner.host.fileSystem.directory(options.kotlinHome).existsSync(),
    );
    final installed = await resolve(
      environment: environment,
      projectRoot: projectRoot,
    );
    if (installed != null) return installed;
    throw XcrossError(
      (await problems(
        environment: environment,
        projectRoot: projectRoot,
      )).join('\n'),
    );
  }

  Future<ResolvedToolchain<T>> _resolved({
    required Map<String, String> environment,
    required String projectRoot,
    required ComposeSetupOptions<T> options,
  }) async {
    final host = target.toolchainHost;
    final problems = <String>[];
    final konancExecutable = host.konancExecutable(options.kotlinHome);
    if (!ComposeToolchainInstaller.isComplete(options)) {
      problems.add(
        'Missing complete Kotlin/Native compiler cache at ${options.kotlinHome}. Run `xcross compose setup` or allow toolchain installation.',
      );
    }
    final java = await ComposeJavaResolver<T>(
      _which,
      _run,
    ).resolve(host, environment, problems);
    final gradle = await _resolveGradle(
      host,
      environment,
      projectRoot,
      problems,
    );
    final swiftc = await _which('swiftc', environment: environment);
    if (swiftc == null) {
      problems.add('Missing swiftc. Install Swift and put swiftc on PATH.');
    }
    final clang = await _which('clang', environment: environment);
    if (clang == null) {
      problems.add('Missing clang. Install LLVM clang and put it on PATH.');
    }
    final sdk = _currentDarwinSdk(null);
    if (sdk == null) {
      problems.add(
        'Missing Darwin SDK. Install with `xcross sdk install <Xcode.xip|Xcode.app>` first.',
      );
    }
    String? sdkPath;
    if (sdk != null) {
      try {
        sdkPath = sdk.iosSdk(target.buildPlatform);
      } on Object catch (error) {
        problems.add('Missing ${target.buildPlatform.sdkName} SDK. $error');
      }
    }
    String? ld64;
    if (sdk != null) {
      try {
        ld64 = await _resolveLd64Lld(sdk);
      } on Object catch (error) {
        problems.add('Missing ld64.lld. $error');
      }
    } else {
      problems.add('Missing ld64.lld. Install LLVM lld with ld64.lld support.');
    }

    if (problems.isNotEmpty ||
        java == null ||
        gradle == null ||
        swiftc == null ||
        clang == null ||
        ld64 == null ||
        sdk == null ||
        sdkPath == null) {
      return ResolvedToolchain(null, problems);
    }
    return ResolvedToolchain(
      ComposeToolchain(
        target: target,
        runner: runner,
        log: log,
        kotlinHome: options.kotlinHome,
        konanCache: options.konanCache,
        konancExecutable: konancExecutable,
        javaHome: java.home,
        javaExecutable: java.executable,
        gradleExecutable: gradle,
        swiftc: swiftc,
        clang: clang,
        ld64Lld: ld64,
        darwinSdkPath: sdkPath,
        darwinSdkBundle: sdk.swiftSdkPath,
      ),
      problems,
    );
  }

  Future<String?> _resolveGradle(
    ComposeHost<T> host,
    Map<String, String> environment,
    String projectRoot,
    List<String> problems,
  ) async {
    final wrapper = runner.host.fileSystem.file(
      host.gradleWrapper(projectRoot),
    );
    if (wrapper.existsSync()) return wrapper.path;
    final gradle = await _which('gradle', environment: environment);
    if (gradle != null) return gradle;
    problems.add(
      'Missing Gradle wrapper or gradle on PATH. Add a Gradle wrapper or install Gradle.',
    );
    return null;
  }
}

@internal
final class ResolvedToolchain<T extends PlatformHostInterface> {
  const ResolvedToolchain(this.toolchain, this.problems);

  final ComposeToolchain<T>? toolchain;
  final List<String> problems;
}
