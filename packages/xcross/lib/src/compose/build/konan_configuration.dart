import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cli_kit/cli_kit.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/compose/project/kmp_project.dart';
import 'package:xcross/src/compose/toolchain/compose_toolchain.dart';
import 'package:xcross/src/compose/toolchain/host_manager_patcher.dart';

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

final class KonanConfiguration {
  const KonanConfiguration()
    : _patchCompilerJar = null,
      _makeExecutable = null,
      _parentEnvironment = null,
      _runningExecutable = null;

  const KonanConfiguration.withSeams({
    KonanPatchCompilerJar? patchCompilerJar,
    MakeExecutable? makeExecutable,
    Map<String, String>? parentEnvironment,
    String? runningExecutable,
  }) : _patchCompilerJar = patchCompilerJar,
       _makeExecutable = makeExecutable,
       _parentEnvironment = parentEnvironment,
       _runningExecutable = runningExecutable;

  static int _stagingCounter = 0;

  final KonanPatchCompilerJar? _patchCompilerJar;
  final MakeExecutable? _makeExecutable;
  final Map<String, String>? _parentEnvironment;
  final String? _runningExecutable;

  Future<PreparedKonanConfiguration> prepare({
    required KmpProject project,
    required ComposeToolchain toolchain,
  }) async {
    final baseDir = p.join(project.root, 'build', 'xcross-ios', 'toolchain');
    final fingerprint = await _fingerprint(toolchain);
    final root = p.join(baseDir, fingerprint);
    final markerPath = p.join(root, '.xcross-complete');
    if (File(markerPath).existsSync()) {
      return _prepared(toolchain: toolchain, root: root);
    }

    final stagingRoot = p.join(
      baseDir,
      '.$fingerprint.staging.$pid.${DateTime.now().microsecondsSinceEpoch}.${_stagingCounter++}',
    );
    try {
      await _prepareStaging(stagingRoot, root, toolchain);
      File(
        p.join(stagingRoot, '.xcross-complete'),
      ).writeAsStringSync('complete\n');
      await Directory(stagingRoot).rename(root);
    } on FileSystemException {
      await _deleteIfExists(Directory(stagingRoot));
      if (File(markerPath).existsSync()) {
        return _prepared(toolchain: toolchain, root: root);
      }
      rethrow;
    } catch (_) {
      await _deleteIfExists(Directory(stagingRoot));
      rethrow;
    }
    return _prepared(toolchain: toolchain, root: root);
  }

  Future<void> _prepareStaging(
    String stagingRoot,
    String finalRoot,
    ComposeToolchain toolchain,
  ) async {
    final kotlinHome = p.join(stagingRoot, 'kotlin-home');
    final configDir = p.join(stagingRoot, 'konan');
    Directory(p.join(kotlinHome, 'bin')).createSync(recursive: true);
    Directory(p.join(kotlinHome, 'konan', 'lib')).createSync(recursive: true);
    Directory(configDir).createSync(recursive: true);
    await _copyMutableKonanFiles(toolchain.kotlinHome, kotlinHome);
    await _patchJars(kotlinHome);
    await _writeAppleToolchain(stagingRoot, toolchain);
    _writeKonanProperties(
      p.join(configDir, 'konan.properties'),
      toolchain,
      finalRoot,
    );
  }

  PreparedKonanConfiguration _prepared({
    required ComposeToolchain toolchain,
    required String root,
  }) {
    final kotlinHome = p.join(root, 'kotlin-home');
    final configDir = p.join(root, 'konan');
    final appleBin = p.join(root, 'apple-toolchain', 'bin');
    final pathSeparator = toolchain.host.isWindows ? ';' : ':';
    final parentEnvironment = _parentEnvironment ?? Platform.environment;
    final parentPath = parentEnvironment['PATH'] ?? '';
    final path = parentPath.isEmpty
        ? appleBin
        : '$appleBin$pathSeparator$parentPath';
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
        ..._appleToolEnvironment(toolchain),
        'PATH': path,
      },
    );
  }

  Future<void> _deleteIfExists(Directory directory) async {
    if (directory.existsSync()) await directory.delete(recursive: true);
  }

  Future<String> _fingerprint(ComposeToolchain toolchain) async {
    final bytes = BytesBuilder();
    void addString(String value) {
      bytes.add(utf8.encode(value));
      bytes.addByte(0);
    }

    addString(toolchain.host.classifier);
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
    if (toolchain.host.isWindows) {
      await _addFile(
        bytes,
        'running-executable',
        File(_runningExecutable ?? Platform.resolvedExecutable),
      );
    }
    await _addFile(
      bytes,
      'konan.properties',
      File(p.join(toolchain.kotlinHome, 'konan', 'konan.properties')),
    );
    final lib = Directory(p.join(toolchain.kotlinHome, 'konan', 'lib'));
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
    final sourceConfig = File(p.join(sourceHome, 'konan', 'konan.properties'));
    if (sourceConfig.existsSync()) {
      await _copyFileIfExists(
        sourceConfig.path,
        p.join(targetHome, 'konan', 'konan.properties'),
      );
    }
    final lib = Directory(p.join(sourceHome, 'konan', 'lib'));
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
    final file = File(source);
    if (!file.existsSync()) return;
    await Directory(p.dirname(target)).create(recursive: true);
    await file.copy(target);
  }

  Future<void> _patchJars(String kotlinHome) async {
    final lib = Directory(p.join(kotlinHome, 'konan', 'lib'));
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
    ComposeToolchain toolchain,
    String root,
  ) {
    final properties = _konanProperties(toolchain, root);
    File(path).writeAsStringSync(
      '${properties.entries.map((entry) => '${entry.key}=${entry.value}').join('\n')}\n',
    );
  }

  Map<String, String> _konanProperties(
    ComposeToolchain toolchain,
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
    properties['linker.$host-ios_arm64'] = '$appleToolchain/bin/ld';
    return properties;
  }

  Future<void> _writeAppleToolchain(
    String stagingRoot,
    ComposeToolchain toolchain,
  ) async {
    final appleToolchain = p.join(stagingRoot, 'apple-toolchain');
    final bin = p.join(appleToolchain, 'bin');
    Directory(bin).createSync(recursive: true);
    // AppleConfigurablesImpl.getAbsoluteTargetToolchain() resolves to
    // "$appleToolchain/usr", and MacOSBasedLinker.compilerRtDir does
    // File("$absoluteTargetToolchain/lib/clang/").getListFiles().firstOrNull()
    // + "/lib/darwin/" — it picks whatever single subdirectory happens to
    // exist under lib/clang (there's normally exactly one, the clang version)
    // and expects Xcode's compiler-rt layout underneath. Kotlin's
    // getListFiles() throws NoSuchFileException (rather than returning an
    // empty list) when lib/clang itself doesn't exist at all, so it must
    // exist; MacOSBasedLinker.provideCompilerRtLibrary then builds an exact
    // filename from there — "$compilerRtDir/libclang_rt.<platform><sim
    // suffix>.a" for a static (non-asan/tsan) link, e.g.
    // ".../lib/clang/<version>/lib/darwin/libclang_rt.ios.a" — and the link
    // step fails with "undefined symbol: __isPlatformVersionAtLeast" (a
    // symbol compiler-rt provides) if that file isn't the real one. Stage
    // the real libclang_rt.*.a files from the local Darwin SDK artifact
    // bundle's own Xcode toolchain into a same-shaped versioned directory,
    // for every Family MacOSBasedLinker's provideCompilerRtLibrary switches
    // on (ios, watchos, tvos, osx — confirmed via its WhenMappings; this
    // compiler has no xrOS/visionOS case, so libclang_rt.xros*.a is never
    // requested and is skipped to keep staging small).
    final clangDir = Directory(p.join(appleToolchain, 'usr', 'lib', 'clang'))
      ..createSync(recursive: true);
    final darwinRt = _findCompilerRtDarwinDir(toolchain.darwinSdkBundle);
    if (darwinRt != null) {
      final stagedDarwin = Directory(
        p.join(clangDir.path, 'xcross', 'lib', 'darwin'),
      )..createSync(recursive: true);
      for (final name in _compilerRtLibraryNames) {
        final source = File(p.join(darwinRt, name));
        if (source.existsSync()) {
          source.copySync(p.join(stagedDarwin.path, name));
        }
      }
    }
    // MacOSBasedLinker's constructor also hardcodes linker/libtool/strip/
    // dsymutil as "$absoluteTargetToolchain/bin/<tool>" (i.e.
    // "$appleToolchain/usr/bin/<tool>"), bypassing any konan.properties
    // override. Stage the same shims there too, or the link step fails
    // with "Cannot run program ".../apple-toolchain/usr/bin/ld"".
    final usrBin = p.join(appleToolchain, 'usr', 'bin');
    Directory(usrBin).createSync(recursive: true);
    const usrBinTools = {'ld', 'strip', 'dsymutil', 'libtool'};
    for (final entry in _appleToolAliases.entries) {
      final name = toolchain.host.isWindows ? '${entry.key}.exe' : entry.key;
      final targets = [bin, if (usrBinTools.contains(entry.key)) usrBin];
      for (final directory in targets) {
        final path = p.join(directory, name);
        if (toolchain.host.isWindows) {
          await File(
            _runningExecutable ?? Platform.resolvedExecutable,
          ).copy(path);
        } else {
          final file = File(path)
            ..writeAsStringSync(_shimScript(entry.key, entry.value));
          (_makeExecutable ?? ProcessRunner.makeExecutable)(file.path);
          if (!Platform.isWindows) {
            Process.runSync('chmod', ['755', file.path]);
          }
        }
      }
    }
  }

  Map<String, String> _appleToolEnvironment(ComposeToolchain toolchain) {
    final directory = p.dirname(toolchain.ld64Lld);
    final extension = toolchain.host.isWindows ? '.exe' : '';
    return {
      'XCROSS_APPLE_TOOL_LD': toolchain.ld64Lld,
      'XCROSS_APPLE_TOOL_STRIP': p.join(directory, 'llvm-strip$extension'),
      'XCROSS_APPLE_TOOL_DSYMUTIL': p.join(directory, 'dsymutil$extension'),
      'XCROSS_APPLE_TOOL_LIBTOOL': p.join(
        directory,
        'llvm-libtool-darwin$extension',
      ),
      'XCROSS_APPLE_TOOL_CLANG': toolchain.clang,
      'XCROSS_APPLE_TOOL_CLANGXX': p.join(
        p.dirname(toolchain.clang),
        'clang++$extension',
      ),
    };
  }

  static Future<void> _defaultPatchCompilerJar(File jar) async {
    patchKotlinNativeJar(jar.path);
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

/// The POSIX shim body staged into the fake Apple toolchain.
///
/// `dsymutil` is not shipped by every LLVM distribution (the swift.org
/// toolchains xcross downloads on Linux have `ld64.lld` and `llvm-strip`
/// but no `dsymutil`). Kotlin/Native's `MacOSBasedLinker` runs it
/// unconditionally after each framework link and fails the build on a
/// nonzero exit, while nothing downstream reads the `.dSYM` bundle, so a
/// missing binary must degrade to a silent no-op (matching the same
/// fallback in the Windows tool-alias dispatcher).
String _shimScript(String tool, String variable) {
  if (tool != 'dsymutil') {
    return '#!/bin/sh\nexec "\$$variable" "\$@"\n';
  }
  return '#!/bin/sh\n'
      'if [ ! -x "\$$variable" ]; then exit 0; fi\n'
      'exec "\$$variable" "\$@"\n';
}

const _appleToolAliases = {
  'ld': 'XCROSS_APPLE_TOOL_LD',
  'strip': 'XCROSS_APPLE_TOOL_STRIP',
  'dsymutil': 'XCROSS_APPLE_TOOL_DSYMUTIL',
  'libtool': 'XCROSS_APPLE_TOOL_LIBTOOL',
  'clang': 'XCROSS_APPLE_TOOL_CLANG',
  'clang++': 'XCROSS_APPLE_TOOL_CLANGXX',
};

String _slash(String value) =>
    p.normalize(value).replaceAll(String.fromCharCode(92), '/');

/// The `libclang_rt.*.a` names `MacOSBasedLinker.provideCompilerRtLibrary`
/// can request for a non-sanitizer static link, one per `Family` it
/// switches on: ios/watchos/tvos/osx, each with a `sim` variant for the
/// simulator triples the patched HostManager also reports as enabled.
const _compilerRtLibraryNames = [
  'libclang_rt.ios.a',
  'libclang_rt.iossim.a',
  'libclang_rt.watchos.a',
  'libclang_rt.watchossim.a',
  'libclang_rt.tvos.a',
  'libclang_rt.tvossim.a',
  'libclang_rt.osx.a',
];

/// Finds `.../XcodeDefault.xctoolchain/usr/lib/clang/<version>/lib/darwin`
/// under a Darwin SDK artifact bundle root, the directory Xcode's own clang
/// ships its compiler-rt static libraries in. Returns null when the bundle
/// doesn't have one (e.g. test fixtures, or a stripped-down bundle), in
/// which case the staged `apple-toolchain` simply ends up with an empty
/// compiler-rt directory again, same as before this fix — no compiler-rt
/// library gets linked in, rather than failing to stage at all.
String? _findCompilerRtDarwinDir(String darwinSdkBundle) {
  final clang = Directory(
    p.join(
      darwinSdkBundle,
      'Developer',
      'Toolchains',
      'XcodeDefault.xctoolchain',
      'usr',
      'lib',
      'clang',
    ),
  );
  if (!clang.existsSync()) return null;
  // Sorted for determinism: Directory.listSync()'s order is filesystem-
  // dependent, and a real Xcode toolchain only ever ships one clang version
  // subdirectory today (confirmed against a live Darwin SDK bundle), so
  // this is inert in practice, but matches the sorted-listing convention
  // DarwinSdk._firstSdk already uses for the analogous iPhoneOS.sdk pick,
  // for the same reason: an unsorted pick from a directory listing is
  // nondeterministic the moment there's ever more than one candidate.
  final versions = clang.listSync().whereType<Directory>().toList()
    ..sort((a, b) => b.path.compareTo(a.path));
  for (final entry in versions) {
    final darwin = p.join(entry.path, 'lib', 'darwin');
    if (Directory(darwin).existsSync()) return darwin;
  }
  return null;
}
