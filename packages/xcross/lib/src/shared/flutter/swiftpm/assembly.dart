import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/apple/mach_o.dart';
import 'package:xcross/src/shared/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_build_services.dart';

@internal
const String flutterFrameworkPackageName = 'FlutterFramework';
@internal
const String pluginsProductName = 'FlutterPluginsGenerated';

@internal
final class SwiftPmAssembly<T extends PlatformHostInterface> {
  SwiftPmAssembly({required this.hostBuildServices, required this.fileSystem});

  final SwiftPmHostBuildServices<T> hostBuildServices;
  final SwiftPmArtifactFileSystem fileSystem;

  /// Finds and fixes every dylib emitted into SwiftPM's target debug output.
  Future<GeneratedPluginsBuildResult> discoverAndRewriteDylibs(
    String targetDebugDir,
  ) async {
    final dylibPaths = <String>[];
    await for (final entity in fileSystem.directory(targetDebugDir).list()) {
      if (entity is File && p.extension(entity.path) == '.dylib') {
        dylibPaths.add(p.absolute(fileSystem.processPath(entity.path)));
      }
    }
    dylibPaths.sort();

    const aggregateName = 'lib$pluginsProductName.dylib';
    final aggregatePath = dylibPaths
        .where((path) => p.basename(path) == aggregateName)
        .firstOrNull;
    if (aggregatePath == null) {
      throw FlutterBuildError(
        'GeneratedPluginsPackage: swift build did not produce the plugins '
        'library in $targetDebugDir',
      );
    }

    final dylibNames = dylibPaths.map(p.basename).toSet();
    for (final path in dylibPaths) {
      await hostBuildServices.rewriteDylib(path, dylibNames);
    }
    // SwiftPM emits .swiftmodule files into a sibling `Modules` directory;
    // app-extension targets importing a plugin need it on their include path.
    final modulesPath = p.join(targetDebugDir, 'Modules');
    final frameworkPaths = <String>[];
    await for (final entity in fileSystem.directory(targetDebugDir).list()) {
      if (entity is! Directory || p.extension(entity.path) != '.framework') {
        continue;
      }
      final binary = fileSystem.file(
        p.join(entity.path, p.basenameWithoutExtension(entity.path)),
      );
      if (binary.existsSync() && isDynamicLibrary(await binary.readAsBytes())) {
        frameworkPaths.add(p.absolute(fileSystem.processPath(entity.path)));
      }
    }
    frameworkPaths.sort();
    return GeneratedPluginsBuildResult(
      libraryPath: aggregatePath,
      dylibPaths: List.unmodifiable(dylibPaths),
      frameworkPaths: List.unmodifiable(frameworkPaths),
      modulesDir: fileSystem.directory(modulesPath).existsSync()
          ? p.absolute(modulesPath)
          : null,
    );
  }

  static bool isDynamicLibrary(Uint8List bytes) {
    if (bytes.length < MachOConstants.headerSize64) return false;
    final data = ByteData.sublistView(bytes);
    if (data.getUint32(0, Endian.little) == MachOConstants.magic64) {
      return data.getUint32(12, Endian.little) == MachOConstants.mhDylib;
    }
    if (data.getUint32(0) != _fatMagic) return false;
    final count = data.getUint32(4);
    for (var index = 0; index < count; index++) {
      final entry = 8 + index * 20;
      if (entry + 20 > bytes.length) return false;
      final offset = data.getUint32(entry + 8);
      if (offset + MachOConstants.headerSize64 > bytes.length) continue;
      if (data.getUint32(offset, Endian.little) == MachOConstants.magic64 &&
          data.getUint32(offset + 12, Endian.little) ==
              MachOConstants.mhDylib) {
        return true;
      }
    }
    return false;
  }

  static const _fatMagic = 0xcafebabe;
}
