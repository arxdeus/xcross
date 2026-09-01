import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/cli/basic/doctor_environment_checks.dart';
import 'package:xcross/src/cli/basic/doctor_models.dart';
import 'package:xcross/src/compose/project/kmp_project.dart';
import 'package:xcross/src/compose/toolchain/compose_host.dart';
import 'package:xcross/src/compose/toolchain/compose_toolchain_resolver.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/flutter/build/flutter_packer.dart';
import 'package:xcross/src/flutter/models/pubspec_info.dart';
import 'package:xcross/src/package_config_resolver.dart';

abstract final class DoctorProjectChecks {
  static DoctorProject? detect(String root) {
    if (File(p.join(root, 'pubspec.yaml')).existsSync()) {
      return DoctorProject.flutter(root);
    }
    if (File(p.join(root, 'settings.gradle.kts')).existsSync() ||
        File(p.join(root, 'settings.gradle')).existsSync()) {
      return DoctorProject.compose(root);
    }
    return null;
  }

  static Future<List<DoctorCheck>> examine(DoctorProject project) =>
      switch (project.kind) {
        DoctorProjectKind.flutter => _flutter(project.root),
        DoctorProjectKind.compose => _compose(project.root),
      };

  static Future<List<DoctorCheck>> _flutter(String root) async {
    final projectCheck = _flutterProject(root);
    if (projectCheck.status == DoctorStatus.failure) return [projectCheck];

    return [
      projectCheck,
      _flutterEntrypoint(root),
      await DoctorEnvironmentChecks.flutterTool(),
      await _flutterSdk(root),
      await _flutterPackages(root),
    ];
  }

  static DoctorCheck _flutterProject(String root) {
    try {
      return DoctorCheck.success(
        'Flutter project',
        PubspecInfo.loadSync(root).name,
      );
    } on Object catch (error) {
      return DoctorCheck.failure('Flutter project', '$error');
    }
  }

  static DoctorCheck _flutterEntrypoint(String root) {
    final entrypoint = File(p.join(root, 'lib', 'main.dart'));
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

  static Future<DoctorCheck> _flutterSdk(String root) async {
    try {
      final flutterRoot = await FlutterPacker.resolveFlutterRoot(
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

  static Future<List<DoctorCheck>> _compose(String root) async {
    try {
      final project = KmpProject.detect(root);
      final projectCheck = DoctorCheck.success(
        'Compose project',
        project.moduleName,
      );
      final host = _resolveComposeHost();
      if (host.problem case final problem?) {
        return [projectCheck, DoctorCheck.failure('Compose host', problem)];
      }
      final problems = await ComposeToolchainResolver.problems(
        host: host.value!,
        environment: ProcessRunner.effectiveEnvironment,
        projectRoot: root,
      );
      return [projectCheck, _composeToolchain(problems)];
    } on Object catch (error) {
      return [DoctorCheck.failure('Compose project', '$error')];
    }
  }

  static ({ComposeHost? value, String? problem}) _resolveComposeHost() {
    try {
      return (value: ComposeHost.current(), problem: null);
    } on XcrossError catch (error) {
      return (value: null, problem: error.message);
    }
  }

  static DoctorCheck _composeToolchain(List<String> problems) =>
      problems.isEmpty
      ? const DoctorCheck.success('Compose toolchain', 'Ready.')
      : DoctorCheck.failure('Compose toolchain', problems.join(' '));
}
