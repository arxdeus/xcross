import 'dart:io';

import 'package:apple_developer_kit/apple_developer_kit.dart';
import 'package:args/command_runner.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:cli_util/cli_logging.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/cli/basic/sdk_install.dart';
import 'package:xcross/src/compose/project/kmp_project.dart';
import 'package:xcross/src/compose/toolchain/compose_host.dart';
import 'package:xcross/src/compose/toolchain/compose_toolchain_resolver.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/flutter/build/flutter_packer.dart';
import 'package:xcross/src/flutter/models/pubspec_info.dart';
import 'package:xcross/src/package_config_resolver.dart';

enum DoctorStatus { success, warning, failure }

final class DoctorCheck {
  const DoctorCheck(this.status, this.name, this.message, {this.path});

  const DoctorCheck.success(this.name, this.message, {this.path})
    : status = DoctorStatus.success;
  const DoctorCheck.warning(this.name, this.message, {this.path})
    : status = DoctorStatus.warning;
  const DoctorCheck.failure(this.name, this.message, {this.path})
    : status = DoctorStatus.failure;

  final DoctorStatus status;
  final String name;
  final String message;
  final String? path;
}

enum DoctorProjectKind { flutter, compose }

final class DoctorProject {
  const DoctorProject(this.kind, this.root);

  const DoctorProject.flutter(this.root) : kind = DoctorProjectKind.flutter;
  const DoctorProject.compose(this.root) : kind = DoctorProjectKind.compose;

  final DoctorProjectKind kind;
  final String root;
}

typedef DoctorExamine = Future<List<DoctorCheck>> Function();
typedef DoctorWriteLine = void Function(String line);
typedef DoctorChecks = Future<List<DoctorCheck>> Function();
typedef DoctorDetectProject = Future<DoctorProject?> Function();
typedef DoctorProjectChecks =
    Future<List<DoctorCheck>> Function(DoctorProject project);

final class DoctorCommand extends Command<void> {
  DoctorCommand()
    : this.withSeams(
        examine: const DoctorExaminer().examine,
        writeLine: Log.logStatus,
      );

  DoctorCommand.withSeams({
    required DoctorExamine examine,
    required DoctorWriteLine writeLine,
  }) : _examine = examine,
       _writeLine = writeLine;

  final DoctorExamine _examine;
  final DoctorWriteLine _writeLine;

  @override
  String get name => 'doctor';

  @override
  String get description =>
      'Check build and run requirements without building or running.';

  @override
  Future<void> run() async {
    final checks = await _examine();
    for (final check in checks) {
      _writeLine(formatCheck(check, ansi: Log.ansi));
    }
    final failures = checks
        .where((check) => check.status == DoctorStatus.failure)
        .length;
    final warnings = checks
        .where((check) => check.status == DoctorStatus.warning)
        .length;
    if (failures > 0) {
      throw XcrossError(
        'Doctor found $failures ${failures == 1 ? 'failure' : 'failures'}.',
      );
    }
    _writeLine(
      warnings == 0
          ? 'No issues found.'
          : 'Doctor found $warnings ${warnings == 1 ? 'warning' : 'warnings'}.',
    );
  }

  static String formatCheck(
    DoctorCheck check, {
    required Ansi ansi,
    String Function(String value)? dim,
  }) {
    final (marker, color) = switch (check.status) {
      DoctorStatus.success => ('✓', ansi.green),
      DoctorStatus.warning => ('!', ansi.yellow),
      DoctorStatus.failure => ('✗', ansi.red),
    };
    final status = '$color[$marker]${ansi.none}';
    final line = '$status ${check.name}: ${check.message}';
    final path = check.path;
    if (path == null) return line;
    final dimPath = (dim ?? Log.dim)(path);
    return '$line\n    $dimPath';
  }
}

final class DoctorExaminer {
  const DoctorExaminer()
    : _hostChecks = _defaultHostChecks,
      _detectProject = _defaultDetectProject,
      _projectChecks = _defaultProjectChecks,
      _runChecks = _defaultRunChecks;

  const DoctorExaminer.withSeams({
    required DoctorChecks hostChecks,
    required DoctorDetectProject detectProject,
    required DoctorProjectChecks projectChecks,
    required DoctorChecks runChecks,
  }) : _hostChecks = hostChecks,
       _detectProject = detectProject,
       _projectChecks = projectChecks,
       _runChecks = runChecks;

  final DoctorChecks _hostChecks;
  final DoctorDetectProject _detectProject;
  final DoctorProjectChecks _projectChecks;
  final DoctorChecks _runChecks;

  Future<List<DoctorCheck>> examine() async {
    final checks = [...await _hostChecks()];
    final project = await _detectProject();
    if (project == null) {
      checks.add(
        const DoctorCheck.warning(
          'Project',
          'No Flutter or Compose project found in the current directory.',
        ),
      );
    } else {
      checks.addAll(await _projectChecks(project));
    }
    checks.addAll(await _runChecks());
    return checks;
  }

  static Future<List<DoctorCheck>> _defaultHostChecks() async {
    final checks = <DoctorCheck>[];
    final supported =
        Platform.isLinux || Platform.isMacOS || Platform.isWindows;
    checks.add(
      supported
          ? DoctorCheck.success(
              'Host',
              '${Platform.operatingSystem} is supported.',
            )
          : DoctorCheck.failure(
              'Host',
              '${Platform.operatingSystem} is not supported.',
            ),
    );
    for (final tool in const [
      'swift',
      'clang',
      'clang++',
      'llvm-ar',
      'ld64.lld',
    ]) {
      final path = await ProcessRunner.which(
        tool,
        accept: tool == 'ld64.lld' ? DarwinSdk.usableLd64Lld : null,
        extraDirectories: DarwinSdk.llvmToolDirs(),
      );
      checks.add(
        path == null
            ? DoctorCheck.failure(
                tool,
                'Not found. Run `xcross setup` after installing Swift.',
              )
            : DoctorCheck.success(tool, 'Found', path: path),
      );
    }
    final sdkPath = DarwinSdk.nativeInstallDir();
    if (!DarwinSdk.isValidBundle(sdkPath)) {
      checks.add(
        const DoctorCheck.failure(
          'Darwin SDK',
          'Missing or incomplete. Run `xcross sdk install <Xcode.xip>`.',
        ),
      );
    } else {
      final mismatch = await SdkInstall.hostToolchainMismatch(sdkPath);
      checks.add(
        mismatch == null
            ? DoctorCheck.success('Darwin SDK', 'Installed', path: sdkPath)
            : DoctorCheck.failure(
                'Darwin SDK',
                '$mismatch Reinstall it with `xcross sdk install <Xcode.xip>`.',
              ),
      );
    }
    return checks;
  }

  static Future<DoctorProject?> _defaultDetectProject() async =>
      detectProjectAt(Directory.current.path);

  static DoctorProject? detectProjectAt(String root) {
    if (File(p.join(root, 'pubspec.yaml')).existsSync()) {
      return DoctorProject.flutter(root);
    }
    if (File(p.join(root, 'settings.gradle.kts')).existsSync() ||
        File(p.join(root, 'settings.gradle')).existsSync()) {
      return DoctorProject.compose(root);
    }
    return null;
  }

  static Future<List<DoctorCheck>> _defaultProjectChecks(
    DoctorProject project,
  ) => switch (project.kind) {
    DoctorProjectKind.flutter => _flutterChecks(project.root),
    DoctorProjectKind.compose => _composeChecks(project.root),
  };

  static Future<List<DoctorCheck>> _flutterChecks(String root) async {
    final checks = <DoctorCheck>[];
    try {
      final pubspec = PubspecInfo.loadSync(root);
      checks.add(DoctorCheck.success('Flutter project', pubspec.name));
    } on Object catch (error) {
      return [DoctorCheck.failure('Flutter project', '$error')];
    }
    final entrypoint = File(p.join(root, 'lib', 'main.dart'));
    checks.add(
      entrypoint.existsSync()
          ? DoctorCheck.success(
              'Flutter entrypoint',
              'Found',
              path: entrypoint.path,
            )
          : const DoctorCheck.failure(
              'Flutter entrypoint',
              'lib/main.dart does not exist.',
            ),
    );
    try {
      final flutterRoot = await FlutterPacker.resolveFlutterRoot(
        projectRoot: root,
      );
      checks.add(
        DoctorCheck.success('Flutter SDK', 'Found', path: flutterRoot),
      );
    } on Object catch (error) {
      checks.add(DoctorCheck.failure('Flutter SDK', '$error'));
    }
    final packageConfig = await PackageConfigResolver.find(root);
    checks.add(
      packageConfig == null
          ? const DoctorCheck.warning(
              'Flutter packages',
              'No package_config.json; `flutter pub get` will be required.',
            )
          : DoctorCheck.success(
              'Flutter packages',
              'Resolved',
              path: packageConfig,
            ),
    );
    return checks;
  }

  static Future<List<DoctorCheck>> _composeChecks(String root) async {
    try {
      final project = KmpProject.detect(root);
      final checks = <DoctorCheck>[
        DoctorCheck.success('Compose project', project.moduleName),
      ];
      ComposeHost host;
      try {
        host = ComposeHost.current();
      } on XcrossError catch (error) {
        checks.add(DoctorCheck.failure('Compose host', error.message));
        return checks;
      }
      final problems = await ComposeToolchainResolver.problems(
        host: host,
        environment: Platform.environment,
        projectRoot: root,
      );
      checks.add(
        problems.isEmpty
            ? const DoctorCheck.success('Compose toolchain', 'Ready.')
            : DoctorCheck.failure('Compose toolchain', problems.join(' ')),
      );
      return checks;
    } on Object catch (error) {
      return [DoctorCheck.failure('Compose project', '$error')];
    }
  }

  static Future<List<DoctorCheck>> _defaultRunChecks() async {
    final checks = <DoctorCheck>[];
    try {
      final invocation = await Pymd.resolve();
      checks.add(
        DoctorCheck.success(
          'Device tools',
          'Found',
          path: invocation.executable,
        ),
      );
    } on Object catch (error) {
      checks.add(DoctorCheck.failure('Device tools', '$error'));
      return checks;
    }
    checks.add(await _authCheck());
    try {
      final devices = await PymdDevices.devices();
      checks.addAll(await deviceChecks(devices));
    } on Object catch (error) {
      checks.add(DoctorCheck.warning('Device', 'Discovery failed: $error'));
    }
    return checks;
  }

  static Future<List<DoctorCheck>> deviceChecks(
    List<Device> devices, {
    Future<int?> Function(Device device)? osMajorVersion,
  }) async {
    if (devices.isEmpty) {
      return const [
        DoctorCheck.warning('Device', 'No connected iOS device found.'),
      ];
    }
    final resolveVersion =
        osMajorVersion ??
        (device) => OsVersion.deviceOSMajorVersion(
          device.udid,
          overTunnel: device.source == DeviceSource.tunneld,
        );
    final checks = <DoctorCheck>[];
    for (final device in devices) {
      final label = '${device.name} (${device.udid})';
      final major = await resolveVersion(device);
      checks.add(
        major == null
            ? DoctorCheck.warning(
                'Device',
                '$label: could not read the iOS version.',
              )
            : major < 17
            ? DoctorCheck.failure(
                'Device',
                '$label runs iOS $major; iOS 17 or later is required.',
              )
            : DoctorCheck.success('Device', '$label runs iOS $major.'),
      );
    }
    return checks;
  }

  static Future<DoctorCheck> _authCheck() async {
    try {
      final session = await GrandSlamSessionStore().load();
      if (session != null && !session.isExpired) {
        return const DoctorCheck.success(
          'Authentication',
          'Apple ID session is available.',
        );
      }
    } on Object catch (error) {
      return DoctorCheck.failure(
        'Authentication',
        'Apple ID session is unusable: $error',
      );
    }
    final path = AscCredentials.defaultConfigPath();
    if (File(path).existsSync()) {
      try {
        final credentials = await AscCredentials.fromFile(path);
        final client = AscClient(credentials);
        try {
          await client.listDevices();
        } finally {
          client.close();
        }
        return const DoctorCheck.success(
          'Authentication',
          'App Store Connect credentials are valid.',
        );
      } on Object catch (error) {
        return DoctorCheck.failure(
          'Authentication',
          'App Store Connect credentials are unusable: $error',
        );
      }
    }
    return const DoctorCheck.failure(
      'Authentication',
      'No credentials found. Run `xcross auth`.',
    );
  }
}
