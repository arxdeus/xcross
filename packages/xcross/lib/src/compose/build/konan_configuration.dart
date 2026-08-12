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

  static int _stagingCounter = 0;

  final KonanPatchCompilerJar? _patchCompilerJar;
  final MakeExecutable? _makeExecutable;

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
      await _prepareStaging(stagingRoot, toolchain);
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
    ComposeToolchain toolchain,
  ) async {
    final kotlinHome = p.join(stagingRoot, 'kotlin-home');
    final configDir = p.join(stagingRoot, 'konan');
    final shimsDir = p.join(stagingRoot, 'shims');
    Directory(p.join(kotlinHome, 'bin')).createSync(recursive: true);
    Directory(p.join(kotlinHome, 'konan', 'lib')).createSync(recursive: true);
    Directory(configDir).createSync(recursive: true);
    Directory(shimsDir).createSync(recursive: true);
    await _copyMutableKonanFiles(toolchain.kotlinHome, kotlinHome);
    await _patchJars(kotlinHome);
    _writeCompilerShim(kotlinHome, toolchain);
    _writeKonanProperties(p.join(configDir, 'konan.properties'), toolchain);
    _writeShims(shimsDir, toolchain);
  }

  PreparedKonanConfiguration _prepared({
    required ComposeToolchain toolchain,
    required String root,
  }) {
    final kotlinHome = p.join(root, 'kotlin-home');
    final configDir = p.join(root, 'konan');
    final shimsDir = p.join(root, 'shims');
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
    addString('compiler-shim-v1');
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

  void _writeCompilerShim(String kotlinHome, ComposeToolchain toolchain) {
    final compilerJar = p.join(
      kotlinHome,
      'konan',
      'lib',
      'kotlin-native-compiler-embeddable.jar',
    );
    final executable = File(
      p.join(
        kotlinHome,
        'bin',
        toolchain.host.isWindows ? 'konanc.bat' : 'konanc',
      ),
    );
    if (toolchain.host.isWindows) {
      executable.writeAsStringSync(
        '@echo off\r\n'
        'set "KONAN_SHIM_HOME=%~dp0.."\r\n'
        '"${_slash(toolchain.javaExecutable)}" -ea -Xmx3G -XX:TieredStopAtLevel=1 -Dfile.encoding=UTF-8 '
        '"-Dkonan.home=${_slash(toolchain.kotlinHome)}" -cp "%KONAN_SHIM_HOME%\\konan\\lib\\${p.basename(compilerJar)}" '
        'org.jetbrains.kotlin.cli.utilities.MainKt konanc %*\r\n',
      );
      return;
    }
    executable.writeAsStringSync(
      '#!/bin/sh\n'
      'KONAN_SHIM_HOME=\$(CDPATH= cd -- "\$(dirname -- "\$0")/.." && pwd)\n'
      'exec "${_slash(toolchain.javaExecutable)}" -ea -Xmx3G -XX:TieredStopAtLevel=1 -Dfile.encoding=UTF-8 '
      '"-Dkonan.home=${_slash(toolchain.kotlinHome)}" -cp "\$KONAN_SHIM_HOME/konan/lib/${p.basename(compilerJar)}" '
      'org.jetbrains.kotlin.cli.utilities.MainKt konanc "\$@"\n',
    );
    (_makeExecutable ?? ProcessRunner.makeExecutable)(executable.path);
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
    if (!Platform.isWindows) Process.runSync('chmod', ['755', file.path]);
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
