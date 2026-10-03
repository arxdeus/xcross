import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/compose/project/kmp_project.dart';
import 'package:xcross/src/compose/toolchain/compose_toolchain.dart';
import 'package:xcross/src/compose/toolchain/host_manager_patcher.dart';
import 'package:xcross/src/shared/compose/apple_toolchain.dart';

typedef KonanPatchCompilerJar = Future<void> Function(File jar);
typedef MakeExecutable = void Function(String path);

final class PreparedKonanConfiguration {
  const PreparedKonanConfiguration({
    required this.kotlinHome,
    required this.konanConfigPath,
    required this.javaExecutable,
    required this.compilerArguments,
    required this.konanPropertyOverrides,
    required this.environment,
  });

  final String kotlinHome;
  final String konanConfigPath;
  final String javaExecutable;
  final List<String> compilerArguments;
  final String konanPropertyOverrides;
  final Map<String, String> environment;
}

final class KonanConfiguration<T extends PlatformHostInterface> {
  KonanConfiguration(this.runner)
    : _patchCompilerJar = null,
      _makeExecutable = null,
      _parentEnvironment = null,
      _runningExecutable = null;

  KonanConfiguration.withSeams(
    this.runner, {
    KonanPatchCompilerJar? patchCompilerJar,
    MakeExecutable? makeExecutable,
    Map<String, String>? parentEnvironment,
    String? runningExecutable,
  }) : _patchCompilerJar = patchCompilerJar,
       _makeExecutable = makeExecutable,
       _parentEnvironment = parentEnvironment,
       _runningExecutable = runningExecutable;

  int _stagingCounter = 0;

  final ProcessRunner<T> runner;
  final KonanPatchCompilerJar? _patchCompilerJar;
  final MakeExecutable? _makeExecutable;
  final Map<String, String>? _parentEnvironment;
  final String? _runningExecutable;

  Future<PreparedKonanConfiguration> prepare({
    required KmpProject project,
    required ComposeToolchain<T> toolchain,
  }) async {
    final baseDir = p.join(
      project.root,
      'build',
      toolchain.target.outputDirectory,
      'toolchain',
    );
    final fingerprint = await _fingerprint(toolchain);
    final root = p.join(baseDir, fingerprint);
    final markerPath = p.join(root, '.xcross-complete');
    if (runner.host.fileSystem.file(markerPath).existsSync()) {
      return _prepared(toolchain: toolchain, root: root);
    }

    final stagingRoot = p.join(
      baseDir,
      '.$fingerprint.staging.$pid.${DateTime.now().microsecondsSinceEpoch}.${_stagingCounter++}',
    );
    try {
      await _prepareStaging(stagingRoot, root, toolchain);
      runner.host.fileSystem
          .file(p.join(stagingRoot, '.xcross-complete'))
          .writeAsStringSync('complete\n');
      await runner.host.fileSystem
          .directory(stagingRoot)
          .rename(runner.host.fileSystem.directory(root).path);
    } on FileSystemException {
      await _deleteIfExists(runner.host.fileSystem.directory(stagingRoot));
      if (runner.host.fileSystem.file(markerPath).existsSync()) {
        return _prepared(toolchain: toolchain, root: root);
      }
      rethrow;
    } catch (_) {
      await _deleteIfExists(runner.host.fileSystem.directory(stagingRoot));
      rethrow;
    }
    return _prepared(toolchain: toolchain, root: root);
  }

  Future<void> _prepareStaging(
    String stagingRoot,
    String finalRoot,
    ComposeToolchain<T> toolchain,
  ) async {
    final kotlinHome = p.join(stagingRoot, 'kotlin-home');
    final configDir = p.join(stagingRoot, 'konan');
    runner.host.fileSystem
        .directory(p.join(kotlinHome, 'bin'))
        .createSync(recursive: true);
    runner.host.fileSystem
        .directory(p.join(kotlinHome, 'konan', 'lib'))
        .createSync(recursive: true);
    runner.host.fileSystem.directory(configDir).createSync(recursive: true);
    await _copyMutableKonanFiles(toolchain.kotlinHome, kotlinHome);
    await _patchJars(kotlinHome);
    await AppleToolchainStager(
      runner,
      runningExecutable: _runningExecutable,
      makeExecutable: _makeExecutable,
    ).stage(stagingRoot, toolchain);
    _writeKonanProperties(
      p.join(configDir, 'konan.properties'),
      toolchain,
      finalRoot,
    );
  }

  PreparedKonanConfiguration _prepared({
    required ComposeToolchain<T> toolchain,
    required String root,
  }) {
    final kotlinHome = p.join(root, 'kotlin-home');
    final configDir = p.join(root, 'konan');
    final appleBin = p.join(root, 'apple-toolchain', 'bin');
    final parentEnvironment = _parentEnvironment ?? runner.effectiveEnvironment;
    final parentPath = parentEnvironment['PATH'] ?? '';
    final path = runner.host.environment.joinPathList([
      appleBin,
      ...runner.host.environment.splitPathList(parentPath),
    ]);
    final compilerJar = p.join(
      kotlinHome,
      'konan',
      'lib',
      'kotlin-native-compiler-embeddable.jar',
    );
    final overrides = _konanProperties(toolchain, root);
    final javaOptions = [
      parentEnvironment['JDK_JAVA_OPTIONS'],
      parentEnvironment['JAVA_OPTS'],
    ].whereType<String>().where((value) => value.isNotEmpty).join(' ');
    return PreparedKonanConfiguration(
      kotlinHome: kotlinHome,
      konanConfigPath: p.join(configDir, 'konan.properties'),
      javaExecutable: toolchain.javaExecutable,
      compilerArguments: [
        '-ea',
        '-Xmx3G',
        '-XX:TieredStopAtLevel=1',
        '-Dfile.encoding=UTF-8',
        '-Dkonan.home=${_slash(toolchain.kotlinHome)}',
        '-cp',
        compilerJar,
        'org.jetbrains.kotlin.cli.utilities.MainKt',
        'konanc',
      ],
      konanPropertyOverrides: overrides.entries
          .map((entry) => '${entry.key}=${entry.value}')
          .join(';'),
      environment: {
        ...parentEnvironment,
        if (toolchain.javaHome.isNotEmpty) 'JAVA_HOME': toolchain.javaHome,
        if (toolchain.konanCache.isNotEmpty)
          'KONAN_DATA_DIR': toolchain.konanCache,
        'KONAN_CONFIG': configDir,
        'KONAN_USE_INTERNAL_SERVER': '1',
        if (javaOptions.isNotEmpty) 'JDK_JAVA_OPTIONS': javaOptions,
        ...AppleToolEnvironment.resolve(toolchain, parentPath),
        'PATH': path,
      },
    );
  }

  Future<void> _deleteIfExists(Directory directory) async {
    if (directory.existsSync()) await directory.delete(recursive: true);
  }

  Future<String> _fingerprint(ComposeToolchain<T> toolchain) async {
    final bytes = BytesBuilder();
    void addString(String value) {
      bytes.add(utf8.encode(value));
      bytes.addByte(0);
    }

    addString(toolchain.host.classifier);
    addString(toolchain.target.konanTarget);
    addString(toolchain.kotlinHome);
    addString(toolchain.konanCache);
    addString(toolchain.konancExecutable);
    addString(toolchain.javaHome);
    addString(toolchain.javaExecutable);
    addString(toolchain.gradleExecutable);
    addString(toolchain.swiftc);
    addString(toolchain.clang);
    addString(toolchain.ld64Lld);
    addString(toolchain.darwinSdkPath);
    // Bump when the staged shim contents change: the fingerprint is what
    // decides whether an already-prepared toolchain root is reused, so a
    // stale root would keep serving the previous shim scripts.
    addString('direct-java-apple-toolchain-v2');
    for (final file in toolchain.host.shimFingerprintFiles(
      _runningExecutable ?? toolchain.host.runningExecutable,
    )) {
      await _addFile(bytes, 'running-executable', file);
    }
    await _addFile(
      bytes,
      'konan.properties',
      runner.host.fileSystem.file(
        p.join(toolchain.kotlinHome, 'konan', 'konan.properties'),
      ),
    );
    final lib = runner.host.fileSystem.directory(
      p.join(toolchain.kotlinHome, 'konan', 'lib'),
    );
    if (lib.existsSync()) {
      final jars =
          lib
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()
              .where((file) => p.basename(file.path).endsWith('.jar'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      for (final jar in jars) {
        await _addFile(bytes, p.relative(jar.path, from: lib.path), jar);
      }
    }
    return sha256.convert(bytes.takeBytes()).toString();
  }

  Future<void> _addFile(BytesBuilder bytes, String label, File file) async {
    bytes.add(utf8.encode(label));
    bytes.addByte(0);
    bytes.add(utf8.encode(file.existsSync() ? file.path : 'missing'));
    bytes.addByte(0);
    if (file.existsSync()) bytes.add(await file.readAsBytes());
    bytes.addByte(0);
  }

  Future<void> _copyMutableKonanFiles(
    String sourceHome,
    String targetHome,
  ) async {
    final sourceConfig = runner.host.fileSystem.file(
      p.join(sourceHome, 'konan', 'konan.properties'),
    );
    if (sourceConfig.existsSync()) {
      await _copyFileIfExists(
        sourceConfig.path,
        p.join(targetHome, 'konan', 'konan.properties'),
      );
    }
    final lib = runner.host.fileSystem.directory(
      p.join(sourceHome, 'konan', 'lib'),
    );
    if (!lib.existsSync()) return;
    await for (final entity in lib.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (!p.basename(entity.path).endsWith('.jar')) continue;
      final relative = p.relative(entity.path, from: lib.path);
      await _copyFileIfExists(
        entity.path,
        p.join(targetHome, 'konan', 'lib', relative),
      );
    }
  }

  Future<void> _copyFileIfExists(String source, String target) async {
    final file = runner.host.fileSystem.file(source);
    if (!file.existsSync()) return;
    await runner.host.fileSystem
        .directory(p.dirname(target))
        .create(recursive: true);
    await file.copy(runner.host.fileSystem.file(target).path);
  }

  Future<void> _patchJars(String kotlinHome) async {
    final lib = runner.host.fileSystem.directory(
      p.join(kotlinHome, 'konan', 'lib'),
    );
    if (!lib.existsSync()) return;
    await for (final entity in lib.list(recursive: true, followLinks: false)) {
      if (entity is File &&
          p.basename(entity.path) == 'kotlin-native-compiler-embeddable.jar') {
        await (_patchCompilerJar ?? _defaultPatchCompilerJar)(entity);
      }
    }
  }

  void _writeKonanProperties(
    String path,
    ComposeToolchain<T> toolchain,
    String root,
  ) {
    final properties = _konanProperties(toolchain, root);
    runner.host.fileSystem
        .file(path)
        .writeAsStringSync(
          '${properties.entries.map((entry) => '${entry.key}=${entry.value}').join('\n')}\n',
        );
  }

  Map<String, String> _konanProperties(
    ComposeToolchain<T> toolchain,
    String root,
  ) {
    final host = toolchain.host.konanTarget;
    final appleToolchain = _slash(p.join(root, 'apple-toolchain'));
    final sdk = _slash(toolchain.darwinSdkPath);
    final properties = <String, String>{
      'additionalToolsDir.$host': appleToolchain,
    };
    // The patched HostManager reports every Apple-family KonanTarget as
    // enabled for a non-macOS host (see host_manager_patcher.dart), so
    // PlatformManager eagerly constructs an AppleConfigurablesImpl for each
    // one during compiler startup, not just the ios_arm64 target xcross
    // actually compiles for. Every one of those constructors requires
    // non-null targetSysRoot/targetToolchain values, otherwise it throws a
    // NullPointerException before konanc ever gets a chance to run. The
    // xcross apple-toolchain/SDK shim is target-agnostic, so reuse it for
    // every Apple target to keep those constructors happy.
    for (final target in _appleKonanTargets) {
      properties['targetSysRoot.$target'] = sdk;
      properties['targetToolchain.$host-$target'] = appleToolchain;
    }
    properties['linker.$host-${toolchain.target.konanTarget}'] =
        '$appleToolchain/bin/ld';
    // konan.properties lists ios_arm64 as cacheable only from macOS hosts, so
    // on any other host Kotlin/Native refuses (or silently ignores) compiler
    // caches for it. Without caches a debug link compiles the program and
    // every dependency (Compose, Ktor, stdlib, ...) into a single LLVM module:
    // for a real Compose app that is one clang process of 10+ GB. Nothing in
    // the caches is host-specific - they are ios_arm64 objects produced by the
    // same compiler - so declare the target cacheable here. This prepared
    // compiler only ever targets ios_arm64, so it is the whole list.
    properties['cacheableTargets.$host'] = toolchain.target.konanTarget;
    return properties;
  }

  Future<void> _defaultPatchCompilerJar(File jar) async {
    KotlinNativeJarPatcher(runner.host.fileSystem).patch(jar.path);
  }
}

/// Every Apple-family [org.jetbrains.kotlin.konan.target.KonanTarget] name.
///
/// The patched Kotlin/Native `HostManager` (see host_manager_patcher.dart)
/// reports all of these as enabled regardless of host, so
/// `PlatformManager`'s constructor builds an `AppleConfigurablesImpl` for
/// every one of them, not just `ios_arm64`. Each of those constructors
/// dereferences `targetSysRoot`/`targetToolchain` unconditionally, so every
/// target listed here needs a non-null override.
const _appleKonanTargets = [
  'macos_x64',
  'macos_arm64',
  'ios_arm64',
  'ios_x64',
  'ios_simulator_arm64',
  'tvos_arm64',
  'tvos_x64',
  'tvos_simulator_arm64',
  'watchos_arm32',
  'watchos_arm64',
  'watchos_device_arm64',
  'watchos_x64',
  'watchos_simulator_arm64',
];

String _slash(String value) =>
    p.normalize(value).replaceAll(String.fromCharCode(92), '/');
