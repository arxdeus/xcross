import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:xcross/src/shared/flutter/build/internal/recursive_directory_copy.dart';
import 'package:xcross/src/shared/flutter/build/pbxproj.dart';
import 'package:xcross/src/shared/flutter/project/pbx_project_reader.dart';

/// What [IosBundleResources.stage] could not copy as-is and left for the
/// resource compiler: Xcode compiles these rather than copying them.
@internal
@immutable
final class StagedIosResources {
  const StagedIosResources({
    this.assetCatalogs = const [],
    this.storyboards = const [],
    this.appIconName,
    this.alternateAppIconNames = const [],
    this.includeAllAppIcons = false,
    this.accentColorName,
    this.deviceFamily,
  });

  /// Absolute paths of the target's `.xcassets`, in build phase order.
  final List<String> assetCatalogs;

  /// Absolute paths of `.storyboard` sources with no precompiled
  /// `.storyboardc` beside them.
  final List<String> storyboards;

  /// The target's `ASSETCATALOG_COMPILER_APPICON_NAME`, when set literally.
  final String? appIconName;

  /// `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`, space separated.
  final List<String> alternateAppIconNames;

  /// `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS = YES`: every other
  /// app icon set is an alternate icon.
  final bool includeAllAppIcons;

  /// `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`, when set literally.
  final String? accentColorName;

  /// `TARGETED_DEVICE_FAMILY` (`"1,2"` -> `[1, 2]`), what Xcode writes as
  /// `UIDeviceFamily` and passes to `actool` as target devices. Null when
  /// unset or unreadable.
  final List<int>? deviceFamily;

  /// The uncompiled storyboard named [name] (`LaunchScreen`), or null.
  String? storyboard(String name, p.Context paths) => storyboards
      .where((path) => paths.basenameWithoutExtension(path) == name)
      .firstOrNull;
}

/// Stages the application target's Xcode resources into an app bundle.
@internal
final class IosBundleResources {
  IosBundleResources(
    this.fileSystem,
    this.paths,
    this.projects, {
    required this.copier,
  });
  final RecursiveDirectoryCopier copier;

  final HostFileSystemInterface fileSystem;
  final p.Context paths;
  final PbxProjectReader projects;

  /// Copies the target's resources into [bundleDir] and returns the asset
  /// catalogs and storyboards that need compiling instead.
  Future<StagedIosResources> stage({
    required String projectRoot,
    required String bundleDir,
    String configuration = 'Debug',
  }) async {
    final pbxprojPath = projects.findPbxproj(projectRoot);
    final project = pbxprojPath == null
        ? null
        : projects.parseFile(pbxprojPath);
    final target = project?.applicationTarget;
    if (project == null || target == null) {
      return _conventionalResources(projectRoot);
    }
    final catalogs = <String>[];
    final storyboards = <String>[];

    final infoPlist = _resolveBuildSettingPath(
      project,
      project.buildSetting(target, 'INFOPLIST_FILE'),
    );
    final resources = <String>{
      ...project.buildPhaseFiles(target, 'PBXResourcesBuildPhase'),
      ...project
          .synchronizedFiles(target, fileSystem: fileSystem)
          .where(PbxProject.isTargetResource),
    };
    for (var source in resources) {
      if (paths.extension(source) == '.xcassets') {
        final catalog = _existingOrRelocated(projectRoot, source);
        if (catalog != null) catalogs.add(catalog);
        continue;
      }
      if (infoPlist != null && paths.equals(source, infoPlist)) continue;

      if (paths.extension(source) == '.storyboard') {
        final compiled = paths.setExtension(source, '.storyboardc');
        if (_sourceType(compiled) == FileSystemEntityType.notFound &&
            _findRelocatedResource(projectRoot, compiled) == null) {
          final storyboard = _existingOrRelocated(projectRoot, source);
          if (storyboard != null) storyboards.add(storyboard);
          continue;
        }
        source = compiled;
      }

      var sourceType = _sourceType(source);
      if (sourceType == FileSystemEntityType.notFound) {
        final relocated = _findRelocatedResource(projectRoot, source);
        if (relocated == null) continue;
        source = relocated;
        sourceType = _sourceType(source);
      }

      final localization = _nearestLocalization(source);
      final isBaseStoryboard =
          paths.extension(source) == '.storyboardc' &&
          localization != null &&
          paths.basename(localization) == 'Base.lproj';
      final destinationDirectory = localization == null || isBaseStoryboard
          ? bundleDir
          : paths.join(bundleDir, paths.basename(localization));
      final destination = paths.join(
        destinationDirectory,
        paths.basename(source),
      );
      await fileSystem.directory(destinationDirectory).create(recursive: true);

      if (sourceType == FileSystemEntityType.directory) {
        final existing = fileSystem.directory(destination);
        if (existing.existsSync()) await existing.delete(recursive: true);
        await copier.copy(source, destination);
      } else if (sourceType == FileSystemEntityType.file &&
          paths.basename(source) == 'AppFrameworkInfo.plist') {
        // Flutter's template lists it in Runner's Resources phase, and
        // Xcode's CopyPlistFile ships it as a binary plist (byte-identical
        // to this conversion, measured with Xcode 26.6).
        await fileSystem
            .file(destination)
            .writeAsBytes(
              binaryPlistResource(await fileSystem.file(source).readAsString()),
            );
      } else if (sourceType == FileSystemEntityType.file) {
        await fileSystem.file(source).copy(fileSystem.file(destination).path);
      }
    }
    final settings = project.buildSettings(
      target,
      preferredConfiguration: configuration,
    );
    String? literal(String key) {
      final value = settings[key];
      final text = switch (value) {
        final String s => s.trim(),
        final num n => '$n',
        _ => null,
      };
      return text == null || text.isEmpty || text.contains(r'$') ? null : text;
    }

    final family = literal(
      'TARGETED_DEVICE_FAMILY',
    )?.split(',').map((v) => int.tryParse(v.trim())).nonNulls.toList();
    return StagedIosResources(
      assetCatalogs: catalogs,
      storyboards: storyboards,
      appIconName: literal('ASSETCATALOG_COMPILER_APPICON_NAME'),
      alternateAppIconNames:
          literal(
            'ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES',
          )?.split(RegExp(r'\s+')).where((n) => n.isNotEmpty).toList() ??
          const [],
      includeAllAppIcons:
          literal('ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS') == 'YES',
      accentColorName: literal(
        'ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME',
      ),
      deviceFamily: family == null || family.isEmpty ? null : family,
    );
  }

  /// The Flutter template's layout, for a project whose Xcode project cannot
  /// be read: `ios/Runner/Assets.xcassets` and `ios/Runner/Base.lproj`.
  StagedIosResources _conventionalResources(String projectRoot) {
    final runner = paths.join(projectRoot, 'ios', 'Runner');
    final catalog = paths.join(runner, 'Assets.xcassets');
    final launch = paths.join(runner, 'Base.lproj', 'LaunchScreen.storyboard');
    return StagedIosResources(
      assetCatalogs: [if (fileSystem.directory(catalog).existsSync()) catalog],
      storyboards: [
        if (fileSystem.file(launch).existsSync() &&
            !fileSystem
                .directory(paths.setExtension(launch, '.storyboardc'))
                .existsSync())
          launch,
      ],
    );
  }

  String? _existingOrRelocated(String projectRoot, String source) =>
      _sourceType(source) != FileSystemEntityType.notFound
      ? source
      : _findRelocatedResource(projectRoot, source);

  FileSystemEntityType _sourceType(String source) {
    if (fileSystem.link(source).existsSync()) return FileSystemEntityType.link;
    if (fileSystem.directory(source).existsSync()) {
      return FileSystemEntityType.directory;
    }
    if (fileSystem.file(source).existsSync()) return FileSystemEntityType.file;
    return FileSystemEntityType.notFound;
  }

  String? _findRelocatedResource(String projectRoot, String unresolved) {
    final ios = fileSystem.directory(paths.join(projectRoot, 'ios'));
    if (!ios.existsSync()) return null;
    final name = paths.basename(unresolved);
    final matches = ios
        .listSync(recursive: true, followLinks: false)
        .where((entity) => paths.basename(entity.path) == name)
        .map(
          (entity) => paths.join(
            projectRoot,
            'ios',
            paths.relative(entity.path, from: ios.path),
          ),
        )
        .toList();
    return matches.length == 1 ? matches.single : null;
  }

  String? _resolveBuildSettingPath(PbxProject project, String? value) {
    if (value == null || value.isEmpty || value.contains(r'$')) return null;
    return paths.normalize(
      paths.isAbsolute(value)
          ? value
          : paths.join(project.projectDirectory, value),
    );
  }

  String? _nearestLocalization(String path) {
    var directory = paths.dirname(path);
    while (directory != paths.dirname(directory)) {
      if (paths.extension(directory) == '.lproj') return directory;
      directory = paths.dirname(directory);
    }
    return null;
  }
}

/// [xml] (a property list) re-encoded as `bplist00`, as Xcode's
/// `CopyPlistFile` writes a `.plist` resource (`builtin-copyPlist
/// --convert binary1`).
@internal
List<int> binaryPlistResource(String xml) {
  final data = PropertyListSerialization.dataWithPropertyList(
    PropertyListSerialization.propertyListWithString(xml),
  );
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}
