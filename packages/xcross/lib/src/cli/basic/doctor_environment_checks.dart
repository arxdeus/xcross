import 'dart:io';

import 'package:apple_developer_kit/apple_developer_kit.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:xcross/src/cli/basic/doctor_models.dart';
import 'package:xcross/src/cli/basic/internal/xcode_swift_requirement.dart';
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
typedef DoctorToolDetail = Future<String?> Function(String path);

abstract final class DoctorEnvironmentChecks {
  static const _requiredTools = ['swift', 'clang++', 'llvm-ar'];

  static Future<List<DoctorCheck>> host() => hostWithSeams(
    operatingSystem: Platform.operatingSystem,
    windows: Platform.isWindows,
    locateTool: ProcessRunner.which,
    iosClang: _resolveIosClang,
    iosLinker: _resolveIosLinker,
    iosLinkerDefect: DarwinSdk.selectorStubDefect,
    iosLinkerDetail: _ld64LldDetail,
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
    DoctorToolDetail? iosLinkerDetail,
  }) async {
    final checks = <DoctorCheck>[_hostPlatform(operatingSystem)];
    for (final tool in _requiredTools) {
      checks.add(await _tool(tool, windows: windows, locateTool: locateTool));
    }
    checks.add(await _buildTool('iOS clang', iosClang));
    checks.add(
      await _buildTool(
        'iOS linker',
        iosLinker,
        defect: iosLinkerDefect,
        detail: iosLinkerDetail,
      ),
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
    DoctorToolDetail? detail,
  }) async {
    final String path;
    try {
      path = await resolve();
    } on Object catch (error) {
      return DoctorCheck.failure(name, error.toString());
    }
    final problem = defect == null ? null : await defect(path);
    if (problem != null) return DoctorCheck.warning(name, problem, path: path);
    final extra = detail == null ? null : await detail(path);
    return DoctorCheck.success(
      name,
      extra == null ? 'Ready' : 'Ready ($extra)',
      path: path,
    );
  }

  /// `LLD <major>.<minor>`, so a healthy linker still reports which one it
  /// is: the selector-stub warning names a bad version, but without this a
  /// good one is indistinguishable from an unknown one.
  static Future<String?> _ld64LldDetail(String path) async {
    final version = await DarwinSdk.ld64LldVersion(path);
    return version == null ? null : 'LLD ${version.$1}.${version.$2}';
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
    if (mismatch != null) {
      return DoctorCheck.failure(
        'Darwin SDK',
        '$mismatch Reinstall it with `xcross sdk install <Xcode.xip>`.',
      );
    }
    final tooOld = await _swiftTooOldForSdk(path);
    if (tooOld != null) return DoctorCheck.failure('Darwin SDK', tooOld);
    // Repairs a bundle installed before xcross rewrote text stubs, so
    // `doctor` reports the SDK the build will actually get rather than the
    // one on disk a moment ago.
    final patched = TbdBundlePatch.ensureApplied(path);
    return DoctorCheck.success(
      'Darwin SDK',
      patched == 0
          ? 'Installed'
          : 'Installed (rewrote $patched text stubs for this linker)',
      path: path,
    );
  }

  /// Why the installed SDK's Xcode generation outruns the host Swift, or null
  /// when the pair is fine or cannot be judged.
  ///
  /// Reported separately from [SdkInstall.hostToolchainMismatch]: that one
  /// asks whether Swift *changed* since the install, while this asks whether
  /// the Swift now on PATH is new enough for this SDK at all. A host that
  /// downgraded Swift, or installed an Xcode 27 SDK with an older `xcross`
  /// that did not yet check, only hears about it here.
  static Future<String?> swiftTooOldForSdk(
    String bundle, {
    Future<Map<String, String>> Function()? toolchainIdentity,
  }) async {
    final int? xcodeMajor;
    try {
      xcodeMajor = XcodeSwiftRequirement.xcodeMajorFromSdkPath(
        DarwinSdk(bundle).iPhoneOSSdk(),
      );
    } on Object catch (error) {
      Log.logTrace('Could not read the installed iPhoneOS SDK version: $error');
      return null;
    }
    if (xcodeMajor == null) return null;
    if (XcodeSwiftRequirement.minimumSwift(xcodeMajor) == null) return null;
    final Map<String, String> identity;
    try {
      identity = await (toolchainIdentity == null
          ? SdkInstall.hostToolchainIdentity()
          : toolchainIdentity());
    } on Object catch (error) {
      Log.logTrace('Could not identify the host Swift toolchain: $error');
      return null;
    }
    return XcodeSwiftRequirement.mismatchWithHint(
      xcodeMajor: xcodeMajor,
      swiftVersionOutput: identity['version'] ?? '',
      swiftPath: identity['swift'],
    );
  }

  static Future<String?> _swiftTooOldForSdk(String bundle) =>
      swiftTooOldForSdk(bundle);

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
