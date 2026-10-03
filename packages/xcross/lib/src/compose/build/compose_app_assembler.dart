import 'dart:io';

import 'package:apple_developer_kit/apple_developer_kit_shared.dart';
import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/compose/build/compose_entitlements.dart';
import 'package:xcross/src/compose/build/compose_info_plist.dart';
import 'package:xcross/src/compose/project/kmp_project.dart';
import 'package:xcross/src/device/internal/app_capabilities.dart';
import 'package:xcross/src/device/internal/app_entitlements.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/target/shared/compose/compose_target.dart';

typedef ComposeCopyDirectory =
    Future<void> Function(Directory source, Directory destination);

typedef ComposeMakeExecutable = void Function(String path);

typedef ComposeSignSimulator = Future<void> Function(String appPath);

typedef ComposeRenameDirectory =
    Future<Directory> Function(Directory source, String newPath);

Future<void> _copyDirectoryNoSymlinks(
  Directory source,
  Directory destination,
  HostFileSystemInterface files,
) async {
  await destination.create(recursive: true);
  await for (final entity in source.list(followLinks: false)) {
    final target = p.join(destination.path, p.basename(entity.path));
    if (entity is Link) continue;
    if (entity is Directory) {
      await _copyDirectoryNoSymlinks(entity, files.directory(target), files);
    } else if (entity is File) {
      await files.directory(p.dirname(target)).create(recursive: true);
      await entity.copy(files.file(target).path);
    }
  }
}

final class ComposeAppAssembler<T extends PlatformHostInterface> {
  ComposeAppAssembler(this.target, this.runner, {required this.log})
    : _copyDirectory = ((source, destination) => _copyDirectoryNoSymlinks(
        source,
        destination,
        target.host.fileSystem,
      )),
      _makeExecutable = runner.makeExecutable,
      _renameDirectory = ((source, newPath) =>
          source.rename(target.host.fileSystem.directory(newPath).path)),
      _finishBundle = ((path) => target.finishBundle(path, runner));
  ComposeAppAssembler.withSeams(
    this.target,
    this.runner, {
    required this.log,
    ComposeCopyDirectory? copyDirectory,
    ComposeMakeExecutable? makeExecutable,
    ComposeRenameDirectory? renameDirectory,
    ComposeSignSimulator? finishBundle,
  }) : _copyDirectory =
           copyDirectory ??
           ((source, destination) => _copyDirectoryNoSymlinks(
             source,
             destination,
             target.host.fileSystem,
           )),
       _makeExecutable = makeExecutable ?? runner.makeExecutable,
       _renameDirectory =
           renameDirectory ??
           ((source, newPath) =>
               source.rename(target.host.fileSystem.directory(newPath).path)),
       _finishBundle =
           finishBundle ?? ((path) => target.finishBundle(path, runner));

  final ComposeTarget<T> target;
  final ProcessRunner<T> runner;
  final Log log;
  final ComposeCopyDirectory _copyDirectory;
  final ComposeMakeExecutable _makeExecutable;
  final ComposeRenameDirectory _renameDirectory;
  final ComposeSignSimulator _finishBundle;

  Future<String> assemble({
    required KmpProject project,
    required String runnerPath,
    required String frameworkPath,
  }) async {
    final runner = target.host.fileSystem.file(runnerPath);
    if (!runner.existsSync()) {
      throw XcrossError('Runner binary not found: $runnerPath');
    }
    final framework = target.host.fileSystem.directory(frameworkPath);
    if (!framework.existsSync()) {
      throw XcrossError('Compose framework not found: $frameworkPath');
    }
    final frameworkBinary = target.host.fileSystem.file(
      p.join(frameworkPath, project.baseName),
    );
    if (!frameworkBinary.existsSync()) {
      throw XcrossError(
        'Compose framework binary not found: ${frameworkBinary.path}',
      );
    }

    final outputDir = p.join(project.root, 'build', target.outputDirectory);
    final outputDirectory = target.host.fileSystem.directory(outputDir);
    final appPath = p.join(outputDir, '${project.appName}.app');
    await outputDirectory.create(recursive: true);

    final stagingContainer = await outputDirectory.createTemp(
      '.${project.appName}.staging.',
    );
    Directory? backupContainer;
    var preserveBackup = false;

    final stagingApp = p.join(stagingContainer.path, '${project.appName}.app');
    String? backupApp;

    try {
      await _buildStagedApp(
        project: project,
        runner: runner,
        framework: framework,
        stagingPath: stagingApp,
      );
      _validateStagedApp(project: project, appPath: stagingApp);
      await _finishBundle(stagingApp);

      final finalDir = target.host.fileSystem.directory(appPath);
      if (finalDir.existsSync()) {
        backupContainer = await outputDirectory.createTemp(
          '.${project.appName}.backup.',
        );
        backupApp = p.join(backupContainer.path, '${project.appName}.app');
        await _renameDirectory(finalDir, backupApp);
        preserveBackup = true;
      }

      try {
        await _renameDirectory(
          target.host.fileSystem.directory(stagingApp),
          appPath,
        );
      } catch (installError) {
        if (backupApp != null &&
            target.host.fileSystem.directory(backupApp).existsSync()) {
          try {
            await _renameDirectory(
              target.host.fileSystem.directory(backupApp),
              appPath,
            );
            preserveBackup = false;
            if (backupContainer!.existsSync()) {
              await backupContainer.delete(recursive: true);
            }
          } catch (restoreError) {
            throw XcrossError(
              'Failed to install staged Compose app at $appPath and failed to restore previous app. '
              'Previous app backup preserved at ${backupContainer!.path}. '
              'Install error: $installError. Restore error: $restoreError',
            );
          }
        }
        rethrow;
      }

      preserveBackup = false;
      if (backupContainer != null && backupContainer.existsSync()) {
        await backupContainer.delete(recursive: true);
      }
      return appPath;
    } finally {
      if (stagingContainer.existsSync()) {
        await stagingContainer.delete(recursive: true);
      }
      if (!preserveBackup &&
          backupContainer != null &&
          backupContainer.existsSync()) {
        await backupContainer.delete(recursive: true);
      }
    }
  }

  Future<void> _buildStagedApp({
    required KmpProject project,
    required File runner,
    required Directory framework,
    required String stagingPath,
  }) async {
    await target.host.fileSystem.directory(stagingPath).create(recursive: true);
    // What the app declares it needs. A profile only grants what the App ID has
    // switched on, so provisioning enables these before the profile is issued.
    final declared = ComposeEntitlements(
      target.host.fileSystem,
    ).read(project.root, project.appName, appDir: project.swiftAppDir);
    final capabilities = AscCapabilities.forEntitlements(declared ?? const {});
    final runnerDest = p.join(stagingPath, 'Runner');
    await runner.copy(target.host.fileSystem.file(runnerDest).path);
    await target.host.fileSystem
        .file(p.join(stagingPath, 'Info.plist'))
        .writeAsString(
          ComposeInfoPlist(target.host.fileSystem, log).build(
            project: project,
            target: target.buildPlatform,
            extras: {
              // Read back at signing time, when the project may be long gone.
              if (capabilities.isNotEmpty)
                AppCapabilities.infoPlistKey: capabilities,
              // The profile grants some keys generically (`associated-domains: *`),
              // and the app's own values are what the runtime checks against.
              if (declared != null && declared.isNotEmpty)
                AppEntitlements.infoPlistKey: declared,
            },
          ),
        );

    // A static framework is linked into Runner, so there is nothing to embed;
    // copying it would ship a ~400 MB archive inside the .app for no reason.
    if (!project.isStaticFramework) {
      await target.host.fileSystem
          .directory(p.join(stagingPath, 'Frameworks'))
          .create(recursive: true);
      final frameworkDest = p.join(
        stagingPath,
        'Frameworks',
        '${project.baseName}.framework',
      );
      await _copyDirectory(
        framework,
        target.host.fileSystem.directory(frameworkDest),
      );
      _makeExecutable(p.join(frameworkDest, project.baseName));
    }

    await _copyComposeResources(
      project: project,
      frameworkPath: framework.path,
      stagingPath: stagingPath,
    );

    _makeExecutable(runnerDest);
  }

  /// Copies the app's Compose resources in as `compose-resources/`.
  ///
  /// Compose Multiplatform keeps resources *outside* the framework. On iOS the
  /// bundle's `compose-resources/` directory plays the role that `assets/` plays
  /// on Android, so it holds the whole resources root — `compose-resources/
  /// composeResources/<package>/…` — which is what `DefaultIOsResourceReader`
  /// resolves against the main bundle. A hand-assembled bundle without it aborts
  /// on the first composition that touches a resource: a font read from the theme
  /// is enough to raise `MissingResourceException` inside `setContent` and kill
  /// the app at launch.
  Future<void> _copyComposeResources({
    required KmpProject project,
    required String frameworkPath,
    required String stagingPath,
  }) async {
    final source = _composeResourcesRoot(project, frameworkPath);
    if (source == null) {
      // A project with no resources is normal and stages nothing. One that has
      // them but whose layout was not recognised would instead ship a bundle
      // that dies on its first resource read, with nothing in the build log to
      // connect the crash to this step - so say so here.
      if (_hasComposeResources(project)) {
        log.logWarn(
          'Compose resources were found under ${p.join(project.modulePath, 'build')} '
          'but not in a layout xcross recognises, so none were staged. The app '
          'will throw MissingResourceException on the first resource it reads.',
        );
      }
      return;
    }
    await _copyDirectory(
      source,
      target.host.fileSystem.directory(
        p.join(stagingPath, 'compose-resources'),
      ),
    );
  }

  /// Whether Gradle produced Compose resources anywhere under the module's
  /// build directory, used only to tell "this project has none" apart from
  /// "this project has some and they were missed".
  bool _hasComposeResources(KmpProject project) {
    final buildDir = target.host.fileSystem.directory(
      p.join(project.modulePath, 'build'),
    );
    if (!buildDir.existsSync()) return false;
    try {
      return buildDir
          .listSync(recursive: true, followLinks: false)
          .whereType<Directory>()
          .any((entity) => p.basename(entity.path) == 'composeResources');
    } on FileSystemException {
      return false;
    }
  }

  /// Gradle's aggregated output for the built target — the only one that also
  /// carries resources contributed by dependencies (coil, koin, …). Returns the
  /// resources *root*, whose contents belong in the bundle: it is the directory
  /// holding `composeResources/`, not that directory itself.
  ///
  /// The framework is always linked for the device target `iosArm64`, so that
  /// target is used whatever the framework path looks like: the production
  /// builder hands over a copy under `build/xcross-ios/`, which names none. The
  /// scanning fallbacks skip simulator and x64 outputs, so a stale simulator
  /// build can never supply a device app's resources.
  Directory? _composeResourcesRoot(KmpProject project, String frameworkPath) {
    for (final candidate in target.resourceCandidates(
      project.modulePath,
      frameworkPath,
    )) {
      if (target.host.fileSystem
          .directory(p.join(candidate, 'composeResources'))
          .existsSync()) {
        return target.host.fileSystem.directory(candidate);
      }
    }
    return null;
  }

  void _validateStagedApp({
    required KmpProject project,
    required String appPath,
  }) {
    final requiredFiles = [
      p.join(appPath, 'Runner'),
      p.join(appPath, 'Info.plist'),
      if (!project.isStaticFramework)
        p.join(
          appPath,
          'Frameworks',
          '${project.baseName}.framework',
          project.baseName,
        ),
    ];
    for (final path in requiredFiles) {
      if (!target.host.fileSystem.file(path).existsSync()) {
        throw XcrossError('Staged Compose app is incomplete: missing $path');
      }
    }
  }
}
