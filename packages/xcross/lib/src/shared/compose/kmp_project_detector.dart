import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/compose/gradle_kmp_metadata.dart';
import 'package:xcross/src/shared/compose/kmp_entry_discovery.dart';
import 'package:xcross/src/shared/compose/project/ios_app_config.dart';
import 'package:xcross/src/shared/compose/project/kmp_project.dart';
import 'package:xcross/src/shared/errors/errors.dart';

final class KmpProjectDetector {
  KmpProjectDetector({
    required this.files,
    required Log log,
    required this.root,
    this.bundleIdOverride,
    this.appNameOverride,
    this.gradleTarget = 'iosArm64',
  }) : metadata = GradleKmpMetadataParser(log),
       entries = KmpEntryDiscovery(files);

  final HostFileSystemInterface files;
  final GradleKmpMetadataParser metadata;
  final KmpEntryDiscovery entries;
  final String root;
  final String? bundleIdOverride;
  final String? appNameOverride;
  final String gradleTarget;

  KmpProject detect() {
    final rootDir = files.directory(root);
    if (!rootDir.existsSync()) {
      throw XcrossError('KMP project root not found: $root');
    }
    final settings = findFile(root, ['settings.gradle.kts', 'settings.gradle']);
    if (settings == null) {
      throw XcrossError(
        'No settings.gradle.kts found in $root. Is this a Gradle KMP project?',
      );
    }
    final modules = metadata.parseIncludedModules(
      settings.readAsStringSync(),
      root,
    );
    if (modules.isEmpty) {
      throw XcrossError('No included modules found in ${settings.path}.');
    }

    final candidates = <ComposeCandidate>[];
    final target = gradleTarget;
    for (final module in modules) {
      final buildFile = findFile(module.diskPath, [
        'build.gradle.kts',
        'build.gradle',
      ]);
      if (buildFile == null) continue;
      final content = metadata.stripComments(buildFile.readAsStringSync());
      if (!metadata.hasIosTarget(content, target) ||
          !metadata.hasFrameworkBlock(content)) {
        continue;
      }
      final framework = metadata.frameworkMetadata(
        content,
        defaultBaseName: _capitalize(module.leaf),
        buildFile: buildFile.path,
        target: target,
      );
      candidates.add(
        ComposeCandidate(
          module.gradleId,
          module.diskPath,
          framework.baseName,
          isStaticFramework: framework.isStatic,
        ),
      );
    }
    if (candidates.isEmpty) {
      throw XcrossError(
        'No KMP module with $target() + binaries.framework found in $root. '
        'Declare $target in your build.gradle.kts files or select '
        'another --target-platform supported by the project.',
      );
    }
    final chosen = candidates.length == 1
        ? candidates.first
        : entries.pickBySwiftImport(root, candidates);
    final entry = entries.classifyEntry(
      chosen.modulePath,
      root,
      chosen.baseName,
    );
    final iosConfig = IosAppConfigLoader(files).load(root);
    final defaults = _defaultIdentity(root);
    return KmpProject(
      root: root,
      modulePath: chosen.modulePath,
      moduleName: chosen.moduleName,
      baseName: chosen.baseName,
      entryKind: entry.kind,
      isStaticFramework: chosen.isStaticFramework,
      // An xcconfig that sets only some keys (the bundle id often lives in
      // the Xcode project instead) must not produce an empty identity.
      bundleId:
          bundleIdOverride ??
          _nonEmpty(iosConfig?.bundleId) ??
          defaults.bundleId,
      appName:
          appNameOverride ??
          _nonEmpty(iosConfig?.productName) ??
          defaults.appName,
      entryClass: entry.entryClass,
      entrySelector: entry.entrySelector,
      swiftAppDir: entry.swiftAppDir,
      swiftSources: entry.swiftSources,
      swiftImports: entry.swiftImports,
      iosConfig: iosConfig,
    );
  }

  File? findFile(String dir, List<String> names) {
    for (final name in names) {
      final file = files.file(p.join(dir, name));
      if (file.existsSync()) return file;
    }
    return null;
  }
}

String _capitalize(String value) =>
    value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);

final class ComposeIdentity {
  const ComposeIdentity(this.bundleId, this.appName);
  final String bundleId;
  final String appName;
}

ComposeIdentity _defaultIdentity(String root) {
  final rawName = p.basename(root);
  final words = RegExp(
    '[A-Za-z0-9]+',
  ).allMatches(rawName).map((m) => m.group(0)!).toList();
  final appName = words.isEmpty ? 'Kmp App' : words.join(' ');
  final bundleLeaf = words.join().toLowerCase();
  return ComposeIdentity(
    'com.example.${bundleLeaf.isEmpty ? 'kmpapp' : bundleLeaf}',
    appName,
  );
}

String? _nonEmpty(String? value) =>
    value == null || value.isEmpty ? null : value;
