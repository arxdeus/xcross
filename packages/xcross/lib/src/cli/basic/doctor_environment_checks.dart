import 'dart:io';

import 'package:apple_developer_kit/apple_developer_kit.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:xcross/src/cli/basic/doctor_models.dart';
import 'package:xcross/src/cli/basic/sdk_install.dart';

typedef DoctorLocateTool =
    Future<String?> Function(
      String name, {
      bool? windows,
      bool Function(String path)? accept,
      Iterable<String> extraDirectories,
    });
typedef DoctorSingleCheck = Future<DoctorCheck> Function();
typedef DoctorResolveTool = Future<String> Function();
typedef DoctorToolDefect = Future<String?> Function(String path);

abstract final class DoctorEnvironmentChecks {
  static const _requiredTools = ['swift', 'clang++', 'llvm-ar'];

  static Future<List<DoctorCheck>> host() => hostWithSeams(
    operatingSystem: Platform.operatingSystem,
    windows: Platform.isWindows,
    locateTool: ProcessRunner.which,
    iosClang: _resolveIosClang,
    iosLinker: _resolveIosLinker,
    iosLinkerDefect: DarwinSdk.selectorStubDefect,
    darwinSdk: _darwinSdk,
  );

  static Future<List<DoctorCheck>> hostWithSeams({
    required String operatingSystem,
    required bool windows,
    required DoctorLocateTool locateTool,
    required DoctorResolveTool iosClang,
    required DoctorResolveTool iosLinker,
    required DoctorSingleCheck darwinSdk,
    DoctorToolDefect? iosLinkerDefect,
  }) async {
    final checks = <DoctorCheck>[_hostPlatform(operatingSystem)];
    for (final tool in _requiredTools) {
      checks.add(await _tool(tool, windows: windows, locateTool: locateTool));
    }
    checks.add(await _buildTool('iOS clang', iosClang));
    checks.add(
      await _buildTool('iOS linker', iosLinker, defect: iosLinkerDefect),
    );
    checks.add(await darwinSdk());
    return checks;
  }

  static DoctorCheck _hostPlatform(String operatingSystem) {
    final supported = const {
      'linux',
      'macos',
      'windows',
    }.contains(operatingSystem);
    final message =
        '$operatingSystem is ${supported ? 'supported' : 'not supported'}.';
    return supported
        ? DoctorCheck.success('Host', message)
        : DoctorCheck.failure('Host', message);
  }

  static Future<DoctorCheck> _tool(
    String name, {
    required bool windows,
    required DoctorLocateTool locateTool,
  }) async {
    final path = await locateTool(
      name,
      windows: windows,
      extraDirectories: DarwinSdk.llvmToolDirs(),
    );
    return path == null
        ? DoctorCheck.failure(
            name,
            'Not found. Run `xcross setup` after installing Swift.',
          )
        : DoctorCheck.success(name, 'Found', path: path);
  }

  /// A tool that resolves but carries a known [defect] still builds, so it
  /// is a warning rather than a failure.
  static Future<DoctorCheck> _buildTool(
    String name,
    DoctorResolveTool resolve, {
    DoctorToolDefect? defect,
  }) async {
    final String path;
    try {
      path = await resolve();
    } on Object catch (error) {
      return DoctorCheck.failure(name, error.toString());
    }
    final problem = defect == null ? null : await defect(path);
    return problem == null
        ? DoctorCheck.success(name, 'Ready', path: path)
        : DoctorCheck.warning(name, problem, path: path);
  }

  static Future<String> _resolveIosClang() {
    final sdk = DarwinSdk.current();
    if (sdk == null) throw StateError('Darwin SDK is not installed.');
    return DarwinSdk.resolveDarwinClang(sdk);
  }

  static Future<String> _resolveIosLinker() {
    final sdk = DarwinSdk.current();
    if (sdk == null) throw StateError('Darwin SDK is not installed.');
    return DarwinSdk.resolveLd64Lld(sdk);
  }

  static Future<DoctorCheck> flutterTool() =>
      flutterToolWithSeams(windows: Platform.isWindows);

  static Future<DoctorCheck> flutterToolWithSeams({
    required bool windows,
    DoctorLocateTool locateTool = ProcessRunner.which,
  }) async {
    final path = await locateTool(
      'flutter',
      windows: windows,
      extraDirectories: const [],
    );
    return path == null
        ? const DoctorCheck.failure(
            'Flutter SDK',
            'Flutter was not found on PATH.',
          )
        : DoctorCheck.success('Flutter SDK', 'Found', path: path);
  }

  static Future<DoctorCheck> _darwinSdk() async {
    final path = DarwinSdk.nativeInstallDir();
    if (!DarwinSdk.isValidBundle(path)) {
      return const DoctorCheck.failure(
        'Darwin SDK',
        'Missing or incomplete. Run `xcross sdk install <Xcode.xip>`.',
      );
    }
    final mismatch = await SdkInstall.hostToolchainMismatch(path);
    return mismatch == null
        ? DoctorCheck.success('Darwin SDK', 'Installed', path: path)
        : DoctorCheck.failure(
            'Darwin SDK',
            '$mismatch Reinstall it with `xcross sdk install <Xcode.xip>`.',
          );
  }

  static Future<List<DoctorCheck>> run() async {
    final deviceTools = await _deviceTools();
    if (deviceTools.status == DoctorStatus.failure) return [deviceTools];

    final checks = <DoctorCheck>[deviceTools, await _authentication()];
    try {
      checks.addAll(await devices(await PymdDevices.devices()));
    } on Object catch (error) {
      checks.add(DoctorCheck.warning('Device', 'Discovery failed: $error'));
    }
    return checks;
  }

  static Future<DoctorCheck> _deviceTools() async {
    try {
      final invocation = await Pymd.resolve();
      return DoctorCheck.success(
        'Device tools',
        'Found',
        path: invocation.executable,
      );
    } on Object catch (error) {
      return DoctorCheck.failure('Device tools', '$error');
    }
  }

  static Future<List<DoctorCheck>> devices(
    List<Device> found, {
    Future<int?> Function(Device device)? osMajorVersion,
  }) async {
    if (found.isEmpty) {
      return const [
        DoctorCheck.warning('Device', 'No connected iOS device found.'),
      ];
    }
    final resolveVersion = osMajorVersion ?? _deviceOsMajorVersion;
    final checks = <DoctorCheck>[];
    for (final device in found) {
      checks.add(_deviceCheck(device, await resolveVersion(device)));
    }
    return checks;
  }

  static Future<int?> _deviceOsMajorVersion(Device device) =>
      OsVersion.deviceOSMajorVersion(
        device.udid,
        overTunnel: device.source == DeviceSource.tunneld,
      );

  static DoctorCheck _deviceCheck(Device device, int? osMajor) {
    final label = '${device.name} (${device.udid})';
    if (osMajor == null) {
      return DoctorCheck.warning(
        'Device',
        '$label: could not read the iOS version.',
      );
    }
    if (osMajor < 17) {
      return DoctorCheck.failure(
        'Device',
        '$label runs iOS $osMajor; iOS 17 or later is required.',
      );
    }
    return DoctorCheck.success('Device', '$label runs iOS $osMajor.');
  }

  static Future<DoctorCheck> _authentication() async {
    final appleId = await _appleIdAuthentication();
    if (appleId != null) return appleId;
    return _appStoreConnectAuthentication();
  }

  static Future<DoctorCheck?> _appleIdAuthentication() async {
    try {
      final session = await GrandSlamSessionStore().load();
      if (session == null || session.isExpired) return null;
      return const DoctorCheck.success(
        'Authentication',
        'Apple ID session is available.',
      );
    } on Object catch (error) {
      return DoctorCheck.failure(
        'Authentication',
        'Apple ID session is unusable: $error',
      );
    }
  }

  static Future<DoctorCheck> _appStoreConnectAuthentication() async {
    final path = AscCredentials.defaultConfigPath();
    if (!File(path).existsSync()) {
      return const DoctorCheck.failure(
        'Authentication',
        'No credentials found. Run `xcross auth`.',
      );
    }
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
}
