import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/compose/build/compose_packer.dart';
import 'package:xcross/src/shared/compose/compose_build_context.dart';
import 'package:xcross/src/shared/compose/kmp_project_detector.dart';
import 'package:xcross/src/shared/compose/models/compose_build_options.dart';
import 'package:xcross/src/shared/compose/project/kmp_project.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/models/pack_result.dart';
import 'package:xcross/src/target/shared/compose/compose_target.dart';

typedef ComposeCurrentDirectory = String Function();
typedef ComposeDetectProject =
    KmpProject Function(
      String root, {
      String? bundleId,
      String? appName,
      String gradleTarget,
    });
typedef ComposePackProject =
    Future<PackResult> Function({
      required KmpProject project,
      required ComposeBuildOptions options,
    });

final class ComposePackOperation<T extends PlatformHostInterface> {
  ComposePackOperation(
    ComposeTarget<T> target, {
    required ProcessRunner<T> runner,
    required DarwinToolchainResolver<T> tools,
    required DarwinSdkRepository<T> sdkRepository,
    required Log log,
    required Downloader downloader,
    String? cacheRoot,
    int processorCount = 1,
  }) : context = ComposeBuildContext(
         target: target,
         runner: runner,
         tools: tools,
         sdkRepository: sdkRepository,
         log: log,
         downloader: downloader,
         cacheRoot: cacheRoot,
         processorCount: processorCount,
       ),
       _currentDirectory = (() => target.host.paths.context.current),
       _detectProject = null,
       _packProject = null;

  ComposePackOperation.withSeams(
    ComposeTarget<T> target, {
    required ProcessRunner<T> runner,
    required DarwinToolchainResolver<T> tools,
    required DarwinSdkRepository<T> sdkRepository,
    required Log log,
    required Downloader downloader,
    required ComposeCurrentDirectory currentDirectory,
    required ComposePackProject packProject,
    String? cacheRoot,
    int processorCount = 1,
    ComposeDetectProject? detectProject,
  }) : context = ComposeBuildContext(
         target: target,
         runner: runner,
         tools: tools,
         sdkRepository: sdkRepository,
         log: log,
         downloader: downloader,
         cacheRoot: cacheRoot,
         processorCount: processorCount,
       ),
       _currentDirectory = currentDirectory,
       _detectProject = detectProject,
       _packProject = packProject;

  final ComposeBuildContext<T> context;
  ComposeTarget<T> get target => context.target;
  ProcessRunner<T> get runner => context.runner;
  DarwinToolchainResolver<T> get tools => context.tools;
  DarwinSdkRepository<T> get sdkRepository => context.sdkRepository;
  Log get log => context.log;
  int get processorCount => context.processorCount;
  Downloader get downloader => context.downloader;
  String? get cacheRoot => context.cacheRoot;
  final ComposeCurrentDirectory _currentDirectory;
  final ComposeDetectProject? _detectProject;
  final ComposePackProject? _packProject;

  Future<PackResult> pack({
    required ComposeBuildOptions options,
    bool requireRunnableApp = false,
  }) async {
    target.validateOutput(ipa: options.ipa);
    final detectProject = _detectProject;
    final project = detectProject == null
        ? KmpProjectDetector(
            files: target.host.fileSystem,
            log: log,
            root: _currentDirectory(),
            bundleIdOverride: options.bundleId,
            appNameOverride: options.appName,
            gradleTarget: target.gradleTarget,
          ).detect()
        : detectProject(
            _currentDirectory(),
            bundleId: options.bundleId,
            appName: options.appName,
            gradleTarget: target.gradleTarget,
          );
    if (project.entryKind == KmpEntryKind.frameworkOnly &&
        (requireRunnableApp || options.ipa)) {
      throw XcrossError('This KMP project produces a framework only.');
    }
    await _deleteStaleOutputs(project);
    final packProject = _packProject;
    if (packProject != null) {
      return packProject(project: project, options: options);
    }
    return ComposePacker(
      project: project,
      options: options,
      target: target,
      runner: runner,
      log: log,
      downloader: downloader,
      tools: tools,
      sdkRepository: sdkRepository,
      cacheRoot: cacheRoot,
      processorCount: processorCount,
    ).pack();
  }

  Future<void> _deleteStaleOutputs(KmpProject project) async {
    for (final path in [
      p.join(
        project.root,
        'build',
        target.outputDirectory,
        '${project.appName}.app',
      ),
      p.join(
        project.root,
        'build',
        target.outputDirectory,
        '${project.baseName}.framework',
      ),
    ]) {
      final entityType = (target.host.fileSystem.link(path).existsSync()
          ? FileSystemEntityType.link
          : target.host.fileSystem.directory(path).existsSync()
          ? FileSystemEntityType.directory
          : target.host.fileSystem.file(path).existsSync()
          ? FileSystemEntityType.file
          : FileSystemEntityType.notFound);
      if (entityType == FileSystemEntityType.directory) {
        await target.host.fileSystem.directory(path).delete(recursive: true);
      } else if (entityType == FileSystemEntityType.file ||
          entityType == FileSystemEntityType.link) {
        await target.host.fileSystem.file(path).delete();
      }
    }
  }
}
