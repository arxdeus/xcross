import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/cli/basic/doctor_models.dart';
import 'package:xcross/src/composition/ios_target.dart';
import 'package:xcross/src/package_config_resolver.dart';
import 'package:xcross/src/shared/compose/kmp_project_detector.dart';
import 'package:xcross/src/shared/diagnostics/doctor_project_inspector.dart';
import 'package:xcross/src/shared/runtime/xcross_runtime.dart';
import 'package:xcross/src/target/shared/runtime/build_features.dart';

final class DoctorProjectChecks<T extends PlatformHostInterface>
    implements DoctorProjectInspector {
  DoctorProjectChecks(this.runtime)
    : features = composePhysicalFeatures(runtime);

  final XcrossBuildFeatures<T> features;

  final XcrossRuntime<T> runtime;
  @override
  DoctorProject? detect(String root) {
    if (runtime.host.fileSystem
        .file(runtime.host.paths.context.join(root, 'pubspec.yaml'))
        .existsSync()) {
      return DoctorProject.flutter(root);
    }
    if (runtime.host.fileSystem
            .file(runtime.host.paths.context.join(root, 'settings.gradle.kts'))
            .existsSync() ||
        runtime.host.fileSystem
            .file(runtime.host.paths.context.join(root, 'settings.gradle'))
            .existsSync()) {
      return DoctorProject.compose(root);
    }
    return null;
  }

  @override
  Future<List<DoctorCheck>> examine(DoctorProject project) =>
      switch (project.kind) {
        DoctorProjectKind.flutter => _flutter(project.root),
        DoctorProjectKind.compose => _compose(project.root),
      };

  Future<List<DoctorCheck>> _flutter(String root) async {
    final projectCheck = _flutterProject(root);
    if (projectCheck.status == DoctorStatus.failure) return [projectCheck];

    return [
      projectCheck,
      _flutterEntrypoint(root),
      await _flutterSdk(root),
      await _flutterPackages(root),
    ];
  }

  DoctorCheck _flutterProject(String root) {
    try {
      return DoctorCheck.success(
        'Flutter project',
        features.flutterRuntime.pubspecs.loadSync(root).name,
      );
    } on Object catch (error) {
      return DoctorCheck.failure('Flutter project', '$error');
    }
  }

  DoctorCheck _flutterEntrypoint(String root) {
    final entrypoint = runtime.host.fileSystem.file(
      runtime.host.paths.context.join(root, 'lib', 'main.dart'),
    );
    return entrypoint.existsSync()
        ? DoctorCheck.success(
            'Flutter entrypoint',
            'Found',
            path: entrypoint.path,
          )
        : const DoctorCheck.failure(
            'Flutter entrypoint',
            'lib/main.dart does not exist.',
          );
  }

  Future<DoctorCheck> _flutterSdk(String root) async {
    try {
      final flutterRoot = await features.flutterRuntime.resolveFlutterRoot(
        projectRoot: root,
      );
      return DoctorCheck.success('Flutter SDK', 'Found', path: flutterRoot);
    } on Object catch (error) {
      return DoctorCheck.failure('Flutter SDK', '$error');
    }
  }

  static Future<DoctorCheck> _flutterPackages(String root) async {
    final packageConfig = await PackageConfigResolver.find(root);
    return packageConfig == null
        ? const DoctorCheck.warning(
            'Flutter packages',
            'No package_config.json; `flutter pub get` will be required.',
          )
        : DoctorCheck.success(
            'Flutter packages',
            'Resolved',
            path: packageConfig,
          );
  }

  Future<List<DoctorCheck>> _compose(String root) async {
    try {
      final project = KmpProjectDetector(
        files: runtime.host.fileSystem,
        log: runtime.log,
        root: root,
      ).detect();
      final projectCheck = DoctorCheck.success(
        'Compose project',
        project.moduleName,
      );
      final problems = await features.composeResolver.problems(
        environment: runtime.runner.effectiveEnvironment,
        projectRoot: root,
      );
      return [projectCheck, _composeToolchain(problems)];
    } on Object catch (error) {
      return [DoctorCheck.failure('Compose project', '$error')];
    }
  }

  static DoctorCheck _composeToolchain(List<String> problems) =>
      problems.isEmpty
      ? const DoctorCheck.success('Compose toolchain', 'Ready.')
      : DoctorCheck.failure('Compose toolchain', problems.join(' '));
}
