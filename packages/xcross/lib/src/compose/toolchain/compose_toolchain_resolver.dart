// ignore_for_file: avoid_dynamic_calls, prefer_constructors_over_static_methods

import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/compose/toolchain/compose_host.dart';
import 'package:xcross/src/compose/toolchain/compose_toolchain.dart';
import 'package:xcross/src/compose/toolchain/compose_toolchain_installer.dart';
import 'package:xcross/src/errors.dart';

const kotlinNativeMavenBase =
    'https://repo.maven.apache.org/maven2/org/jetbrains/kotlin/'
    'kotlin-native-prebuilt';

final class ComposeSetupOptions {
  const ComposeSetupOptions({
    required this.host,
    required this.version,
    required this.projectRoot,
    required this.cacheRoot,
    required this.kotlinHome,
    required this.konanCache,
    required this.hostArchiveUrl,
    required this.overlayArchiveUrl,
    required this.hostArchiveSha256,
    required this.overlayArchiveSha256,
  });

  static const defaultKotlinNativeVersion = '2.2.20';

  final ComposeHost host;
  final String version;
  final String projectRoot;
  final String cacheRoot;
  final String kotlinHome;
  final String konanCache;
  final String hostArchiveUrl;
  final String overlayArchiveUrl;
  final String? hostArchiveSha256;
  final String? overlayArchiveSha256;

  static ComposeSetupOptions resolve({
    required Map<String, String> env,
    required String projectRoot,
    required ComposeHost host,
  }) {
    final version = _version(env, projectRoot);
    final home =
        env['KONAN_DATA_DIR'] ?? env['HOME'] ?? env['USERPROFILE'] ?? '.';
    final cacheRoot = p.join(home, '.konan');
    return ComposeSetupOptions(
      host: host,
      version: version,
      projectRoot: projectRoot,
      cacheRoot: cacheRoot,
      kotlinHome: p.join(
        cacheRoot,
        'kotlin-native-prebuilt-${host.classifier}-$version',
      ),
      konanCache: p.join(cacheRoot, 'cache'),
      hostArchiveUrl:
          '$kotlinNativeMavenBase/$version/${host.hostArtifact(version)}',
      overlayArchiveUrl:
          '$kotlinNativeMavenBase/$version/${ComposeHost.macosX64OverlayArtifact(version)}',
      hostArchiveSha256: _sha256ByArtifact[host.hostArtifact(version)],
      overlayArchiveSha256:
          _sha256ByArtifact[ComposeHost.macosX64OverlayArtifact(version)],
    );
  }

  static const Map<String, String> _sha256ByArtifact = {
    'kotlin-native-prebuilt-2.2.20-linux-x86_64.tar.gz':
        '5e2c25c7783f2a7f89aafeb3ccfb0fb5a671e0e32d283c3ab335dc5e29f19e32',
    'kotlin-native-prebuilt-2.2.20-windows-x86_64.zip':
        '2bf86caed1b5a67f0cd15c685cb8584a2e61f3221d0985f4fc6a590f51c398df',
    'kotlin-native-prebuilt-2.2.20-macos-x86_64.tar.gz':
        'ca9eb2dbb87703176bdbafaad887dc5036c9e5dbfd2eec113b7f4f4a346ca60b',
    'kotlin-native-prebuilt-2.4.0-linux-x86_64.tar.gz':
        '1fdad03264fc398d24df961bf6563e35b82706bb67cf3ba926eb7b768ce7d536',
    'kotlin-native-prebuilt-2.4.0-windows-x86_64.zip':
        'cf91af2dbe53767ec89d0eb0f744e588f316a8d115e5faba401ae3f2db7db535',
    'kotlin-native-prebuilt-2.4.0-macos-x86_64.tar.gz':
        'da0684965d6f33c55b5e6e85b6de8a5327dbd3ccfedcb1ab6c1131900e8b3e83',
  };

  static String _version(Map<String, String> env, String projectRoot) {
    final explicit = env['KN_VERSION'];
    if (explicit != null && explicit.trim().isNotEmpty) return explicit.trim();

    final catalog = File(p.join(projectRoot, 'gradle', 'libs.versions.toml'));
    if (catalog.existsSync()) {
      final match = RegExp(
        r'''(?:^|\n)\s*(?:kotlin|kotlinNative|kotlin-native)\s*=\s*["']([^"']+)["']''',
      ).firstMatch(catalog.readAsStringSync());
      if (match != null) return match.group(1)!;
    }

    final properties = File(p.join(projectRoot, 'gradle.properties'));
    if (properties.existsSync()) {
      for (final line in properties.readAsLinesSync()) {
        final match = RegExp(
          r'^\s*(?:kotlin\.version|kotlinNative\.version)\s*=\s*(\S+)',
        ).firstMatch(line);
        if (match != null) return match.group(1)!;
      }
    }

    return defaultKotlinNativeVersion;
  }
}

typedef ComposeWhich =
    Future<String?> Function(
      String name, {
      Map<String, String>? environment,
      bool? windows,
      Iterable<String> extraDirectories,
    });

typedef ComposeRun =
    Future<ComposeProcessResult> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    });

final class ComposeProcessResult {
  const ComposeProcessResult(this.exitCode, this.stdout, this.stderr);

  final int exitCode;
  final String stdout;
  final String stderr;
}

typedef CurrentDarwinSdk = dynamic Function(String? bundle);
typedef ResolveLd64Lld =
    Future<String> Function(dynamic sdk, {dynamic runProcess});

abstract final class ComposeToolchainResolver {
  static final InjectedComposeToolchainResolver _default = withSeams();

  static InjectedComposeToolchainResolver withSeams({
    ComposeWhich? which,
    ComposeRun? run,
    CurrentDarwinSdk? currentDarwinSdk,
    ResolveLd64Lld? resolveLd64Lld,
    ComposeToolchainInstaller? installer,
  }) => InjectedComposeToolchainResolver._(
    which: which ?? _defaultWhich,
    run: run ?? _defaultRun,
    currentDarwinSdk:
        currentDarwinSdk ?? ((bundle) => DarwinSdk.current(bundle: bundle)),
    resolveLd64Lld:
        resolveLd64Lld ??
        ((sdk, {runProcess}) => DarwinSdk.resolveLd64Lld(sdk as DarwinSdk)),
    installer: installer ?? const ComposeToolchainInstaller(),
  );

  static Future<ComposeToolchain?> resolve({
    required ComposeHost host,
    required Map<String, String> environment,
    required String projectRoot,
  }) => _default.resolve(
    host: host,
    environment: environment,
    projectRoot: projectRoot,
  );

  static Future<List<String>> problems({
    required ComposeHost host,
    required Map<String, String> environment,
    required String projectRoot,
  }) => _default.problems(
    host: host,
    environment: environment,
    projectRoot: projectRoot,
  );

  static Future<ComposeToolchain> ensure({
    required ComposeHost host,
    required Map<String, String> environment,
    required String projectRoot,
    bool allowInstall = true,
    bool force = false,
  }) => _default.ensure(
    host: host,
    environment: environment,
    projectRoot: projectRoot,
    allowInstall: allowInstall,
    force: force,
  );

  static Future<String?> _defaultWhich(
    String name, {
    Map<String, String>? environment,
    bool? windows,
    Iterable<String> extraDirectories = const [],
  }) => ProcessRunner.which(
    name,
    environment: environment,
    windows: windows,
    extraDirectories: extraDirectories,
  );

  static Future<ComposeProcessResult> _defaultRun(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    final result = await ProcessRunner.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );
    return ComposeProcessResult(result.exitCode, result.stdout, result.stderr);
  }
}

final class InjectedComposeToolchainResolver {
  const InjectedComposeToolchainResolver._({
    required ComposeWhich which,
    required ComposeRun run,
    required CurrentDarwinSdk currentDarwinSdk,
    required ResolveLd64Lld resolveLd64Lld,
    required ComposeToolchainInstaller installer,
  }) : _which = which,
       _run = run,
       _currentDarwinSdk = currentDarwinSdk,
       _resolveLd64Lld = resolveLd64Lld,
       _installer = installer;

  final ComposeWhich _which;
  final ComposeRun _run;
  final CurrentDarwinSdk _currentDarwinSdk;
  final ResolveLd64Lld _resolveLd64Lld;
  final ComposeToolchainInstaller _installer;

  Future<ComposeToolchain?> resolve({
    required ComposeHost host,
    required Map<String, String> environment,
    required String projectRoot,
  }) async {
    final options = ComposeSetupOptions.resolve(
      env: environment,
      projectRoot: projectRoot,
      host: host,
    );
    final found = await _resolved(
      host: host,
      environment: environment,
      projectRoot: projectRoot,
      options: options,
    );
    return found.problems.isEmpty ? found.toolchain : null;
  }

  Future<List<String>> problems({
    required ComposeHost host,
    required Map<String, String> environment,
    required String projectRoot,
  }) async {
    final options = ComposeSetupOptions.resolve(
      env: environment,
      projectRoot: projectRoot,
      host: host,
    );
    final found = await _resolved(
      host: host,
      environment: environment,
      projectRoot: projectRoot,
      options: options,
    );
    return found.problems;
  }

  Future<ComposeToolchain> ensure({
    required ComposeHost host,
    required Map<String, String> environment,
    required String projectRoot,
    bool allowInstall = true,
    bool force = false,
  }) async {
    final options = ComposeSetupOptions.resolve(
      env: environment,
      projectRoot: projectRoot,
      host: host,
    );
    final found = await _resolved(
      host: host,
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
      force: force || Directory(options.kotlinHome).existsSync(),
    );
    final installed = await resolve(
      host: host,
      environment: environment,
      projectRoot: projectRoot,
    );
    if (installed != null) return installed;
    throw XcrossError(
      (await problems(
        host: host,
        environment: environment,
        projectRoot: projectRoot,
      )).join('\n'),
    );
  }

  Future<_ResolvedToolchain> _resolved({
    required ComposeHost host,
    required Map<String, String> environment,
    required String projectRoot,
    required ComposeSetupOptions options,
  }) async {
    final problems = <String>[];
    final konancExecutable = host.konancExecutable(options.kotlinHome);
    if (!ComposeToolchainInstaller.isComplete(options)) {
      problems.add(
        'Missing complete Kotlin/Native compiler cache at ${options.kotlinHome}. Run `xcross compose setup` or allow toolchain installation.',
      );
    }
    final java = await _resolveJava(host, environment, problems);
    final gradle = await _resolveGradle(
      host,
      environment,
      projectRoot,
      problems,
    );
    final swiftc = await _which(
      'swiftc',
      environment: environment,
      windows: host.isWindows,
    );
    if (swiftc == null) {
      problems.add('Missing swiftc. Install Swift and put swiftc on PATH.');
    }
    final clang = await _which(
      'clang',
      environment: environment,
      windows: host.isWindows,
    );
    if (clang == null) {
      problems.add('Missing clang. Install LLVM clang and put it on PATH.');
    }
    final sdk = _currentDarwinSdk(null);
    if (sdk == null) {
      problems.add(
        'Missing Darwin SDK. Install with `xcross sdk install <Xcode.xip|Xcode.app>` first.',
      );
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
        sdk == null) {
      return _ResolvedToolchain(null, problems);
    }
    return _ResolvedToolchain(
      ComposeToolchain(
        host: host,
        kotlinHome: options.kotlinHome,
        konanCache: options.konanCache,
        konancExecutable: konancExecutable,
        javaHome: java.home,
        javaExecutable: java.executable,
        gradleExecutable: gradle,
        swiftc: swiftc,
        clang: clang,
        ld64Lld: ld64,
        darwinSdkPath: sdk.swiftSdkPath as String,
      ),
      problems,
    );
  }

  Future<_Java?> _resolveJava(
    ComposeHost host,
    Map<String, String> environment,
    List<String> problems,
  ) async {
    final javaHome = environment['JAVA_HOME'];
    final candidate = javaHome == null
        ? await _which(
            'java',
            environment: environment,
            windows: host.isWindows,
          )
        : host.javaExecutable(javaHome);
    if (candidate == null) {
      problems.add(
        'Missing JDK 21+. Set JAVA_HOME to a JDK 21+ install or put java on PATH.',
      );
      return null;
    }
    final result = await _run(candidate, const [
      '-version',
    ], environment: environment);
    final output = '${result.stdout}\n${result.stderr}';
    final version = RegExp(r'version "(\d+)').firstMatch(output)?.group(1);
    if (result.exitCode != 0 || version == null || int.parse(version) < 21) {
      problems.add(
        'Missing JDK 21+. Found java at $candidate but it is not Java 21+.',
      );
      return null;
    }
    return _Java(javaHome ?? p.dirname(p.dirname(candidate)), candidate);
  }

  Future<String?> _resolveGradle(
    ComposeHost host,
    Map<String, String> environment,
    String projectRoot,
    List<String> problems,
  ) async {
    final wrapper = File(
      p.join(projectRoot, host.isWindows ? 'gradlew.bat' : 'gradlew'),
    );
    if (wrapper.existsSync()) return wrapper.path;
    final gradle = await _which(
      'gradle',
      environment: environment,
      windows: host.isWindows,
    );
    if (gradle != null) return gradle;
    problems.add(
      'Missing Gradle wrapper or gradle on PATH. Add a Gradle wrapper or install Gradle.',
    );
    return null;
  }
}

final class _ResolvedToolchain {
  const _ResolvedToolchain(this.toolchain, this.problems);

  final ComposeToolchain? toolchain;
  final List<String> problems;
}

final class _Java {
  const _Java(this.home, this.executable);

  final String home;
  final String executable;
}
