import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
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
    required this.konancExecutable,
    required this.environment,
  });

  final String kotlinHome;
  final String konanConfigPath;
  final String konancExecutable;
  final Map<String, String> environment;
}

final class KonanConfiguration {
  const KonanConfiguration() : _patchCompilerJar = null, _makeExecutable = null;

  const KonanConfiguration.withSeams({
    KonanPatchCompilerJar? patchCompilerJar,
    MakeExecutable? makeExecutable,
  }) : _patchCompilerJar = patchCompilerJar,
       _makeExecutable = makeExecutable;

  final KonanPatchCompilerJar? _patchCompilerJar;
  final MakeExecutable? _makeExecutable;

  Future<PreparedKonanConfiguration> prepare({
    required KmpProject project,
    required ComposeToolchain toolchain,
  }) async {
    final root = p.join(project.root, 'build', 'xcross-ios', 'toolchain');
    final kotlinHome = p.join(root, 'kotlin-home');
    final configDir = p.join(root, 'konan');
    final shimsDir = p.join(root, 'shims');
    if (Directory(root).existsSync()) {
      Directory(root).deleteSync(recursive: true);
    }
    Directory(p.join(kotlinHome, 'bin')).createSync(recursive: true);
    Directory(p.join(kotlinHome, 'konan', 'lib')).createSync(recursive: true);
    Directory(configDir).createSync(recursive: true);
    Directory(shimsDir).createSync(recursive: true);

    await _copyFileIfExists(
      toolchain.konancExecutable,
      p.join(kotlinHome, 'bin', p.basename(toolchain.konancExecutable)),
    );
    await _copyMutableKonanFiles(toolchain.kotlinHome, kotlinHome);
    await _patchJars(kotlinHome);
    _writeKonanProperties(p.join(configDir, 'konan.properties'), toolchain);
    _writeShims(shimsDir, toolchain);

    final pathSeparator = toolchain.host.isWindows ? ';' : ':';
    final parentPath = Platform.environment['PATH'] ?? '';
    final path = parentPath.isEmpty
        ? shimsDir
        : '$shimsDir$pathSeparator$parentPath';
    return PreparedKonanConfiguration(
      kotlinHome: kotlinHome,
      konanConfigPath: p.join(configDir, 'konan.properties'),
      konancExecutable: p.join(
        kotlinHome,
        'bin',
        toolchain.host.isWindows ? 'konanc.bat' : 'konanc',
      ),
      environment: {
        ...Platform.environment,
        if (toolchain.javaHome.isNotEmpty) 'JAVA_HOME': toolchain.javaHome,
        if (toolchain.konanCache.isNotEmpty)
          'KONAN_DATA_DIR': toolchain.konanCache,
        'KONAN_CONFIG': configDir,
        'PATH': path,
      },
    );
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

  void _writeKonanProperties(String path, ComposeToolchain toolchain) {
    File(path).writeAsStringSync('''
targetSysRoot.ios_arm64=${_slash(toolchain.darwinSdkPath)}
linker.ios_arm64=${_slash(toolchain.ld64Lld)}
toolchainDependency.appleClang.ios_arm64=${_slash(toolchain.clang)}
toolchainDependency.appleSwift.ios_arm64=${_slash(toolchain.swiftc)}
''');
  }

  void _writeShims(String shimsDir, ComposeToolchain toolchain) {
    if (toolchain.host.isWindows) {
      _writeWindowsShim(shimsDir, 'xcrun', toolchain.clang);
      _writeWindowsShim(shimsDir, 'xcode-select', toolchain.clang);
      _writeWindowsShim(shimsDir, 'PlistBuddy', toolchain.clang);
      return;
    }
    _writeShellShim(shimsDir, 'xcrun', toolchain.clang);
    _writeShellShim(shimsDir, 'xcode-select', toolchain.clang);
    _writeShellShim(shimsDir, 'PlistBuddy', toolchain.clang);
  }

  void _writeShellShim(String dir, String name, String tool) {
    final file = File(p.join(dir, name));
    file.writeAsStringSync(
      ['#!/bin/sh', 'exec "${_slash(tool)}" "\$@"', ''].join('\n'),
    );
    (_makeExecutable ?? ProcessRunner.makeExecutable)(file.path);
  }

  void _writeWindowsShim(String dir, String name, String tool) {
    File(
      p.join(dir, '$name.cmd'),
    ).writeAsStringSync('@echo off\r\ncmd.exe /d /c "${_slash(tool)}" %*\r\n');
  }

  static Future<void> _defaultPatchCompilerJar(File jar) async {
    patchKotlinNativeJar(jar.path);
  }
}

String _slash(String value) =>
    p.normalize(value).replaceAll(String.fromCharCode(92), '/');
