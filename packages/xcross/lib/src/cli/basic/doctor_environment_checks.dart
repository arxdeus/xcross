import 'package:apple_developer_kit/apple_developer_kit_shared.dart';
import 'package:cli_kit/cli_kit_shared.dart';
import 'package:dart_mobile_device/dart_mobile_device_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:http/http.dart' as http;
import 'package:xcross/src/cli/basic/doctor_models.dart';
import 'package:xcross/src/cli/basic/internal/xcode_swift_requirement.dart';

typedef DoctorLocateTool =
    Future<String?> Function(
      String name, {
      bool Function(String path)? accept,
      Iterable<String> extraDirectories,
    });
typedef DoctorSingleCheck = Future<DoctorCheck> Function();
typedef DoctorResolveTool = Future<String> Function();
typedef DoctorToolDefect = Future<String?> Function(String path);
typedef DoctorToolDetail = Future<String?> Function(String path);

final class DoctorEnvironmentChecks<T extends PlatformHostInterface> {
  DoctorEnvironmentChecks({
    required this.hostPlatform,
    required this.buildPlatform,
    required this.appleHostServices,
    required this.runner,
    required this.repository,
    required this.toolchain,
    required this.deviceDiagnostics,
    required this.sdkMismatch,
    required this.sdkToolchainIdentity,
    required this.createAppleHttpClient,
  });
  final http.Client Function() createAppleHttpClient;
  final T hostPlatform;
  final IosBuildPlatformInterface buildPlatform;
  final AppleHostServices appleHostServices;
  final ProcessRunner<T> runner;
  final DarwinSdkRepository<T> repository;
  final DarwinToolchainResolver<T> toolchain;
  final DeviceDiagnostics deviceDiagnostics;
  final Future<String?> Function(String bundle) sdkMismatch;
  final Future<Map<String, String>> Function() sdkToolchainIdentity;

  static const _requiredTools = ['swift', 'clang++', 'llvm-ar'];

  Future<List<DoctorCheck>> host() => hostWithSeams(
    hostName: hostPlatform.name,
    llvmDirectories: toolchain.llvmToolDirs(),
    locateTool: runner.which,
    iosClang: _resolveIosClang,
    iosLinker: _resolveIosLinker,
    iosLinkerDefect: toolchain.selectorStubDefect,
    iosLinkerDetail: _ld64LldDetail,
    darwinSdk: _darwinSdk,
  );

  static Future<List<DoctorCheck>> hostWithSeams({
    required String hostName,
    required DoctorLocateTool locateTool,
    required DoctorResolveTool iosClang,
    required DoctorResolveTool iosLinker,
    required DoctorSingleCheck darwinSdk,
    Iterable<String> llvmDirectories = const [],
    DoctorToolDefect? iosLinkerDefect,
    DoctorToolDetail? iosLinkerDetail,
  }) async {
    final checks = <DoctorCheck>[
      DoctorCheck.success('Host', '$hostName is supported.'),
    ];
    for (final tool in _requiredTools) {
      checks.add(
        await _tool(
          tool,
          llvmDirectories: llvmDirectories,
          locateTool: locateTool,
        ),
      );
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

  static Future<DoctorCheck> _tool(
    String name, {
    required Iterable<String> llvmDirectories,
    required DoctorLocateTool locateTool,
  }) async {
    final path = await locateTool(name, extraDirectories: llvmDirectories);
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
  Future<String?> _ld64LldDetail(String path) async {
    final version = await toolchain.ld64LldVersion(path);
    return version == null ? null : 'LLD ${version.$1}.${version.$2}';
  }

  Future<String> _resolveIosClang() {
    final sdk = repository.current();
    if (sdk == null) throw StateError('Darwin SDK is not installed.');
    return toolchain.resolveDarwinClang(
      repository.iosSdk(sdk, target: buildPlatform),
    );
  }

  Future<String> _resolveIosLinker() {
    final sdk = repository.current();
    if (sdk == null) throw StateError('Darwin SDK is not installed.');
    return toolchain.resolveLd64Lld();
  }

  Future<DoctorCheck> flutterTool() =>
      flutterToolWithSeams(locateTool: runner.which);

  static Future<DoctorCheck> flutterToolWithSeams({
    required DoctorLocateTool locateTool,
  }) async {
    final path = await locateTool('flutter', extraDirectories: const []);
    return path == null
        ? const DoctorCheck.failure(
            'Flutter SDK',
            'Flutter was not found on PATH.',
          )
        : DoctorCheck.success('Flutter SDK', 'Found', path: path);
  }

  Future<DoctorCheck> _darwinSdk() async {
    final path = repository.installBundle;
    if (!repository.isValidBundle(path)) {
      return const DoctorCheck.failure(
        'Darwin SDK',
        'Missing or incomplete. Run `xcross sdk install <Xcode.xip>`.',
      );
    }
    final mismatch = await sdkMismatch(path);
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
    final patched = repository.patch.ensureApplied(path);
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
    required Future<Map<String, String>> Function() toolchainIdentity,
    required String Function(String bundle) sdkPath,
    required Log log,
  }) async {
    final int? xcodeMajor;
    try {
      xcodeMajor = XcodeSwiftRequirement.xcodeMajorFromSdkPath(sdkPath(bundle));
    } on Object catch (error) {
      log.logTrace('Could not read the installed iPhoneOS SDK version: $error');
      return null;
    }
    if (xcodeMajor == null) return null;
    if (XcodeSwiftRequirement.minimumSwift(xcodeMajor) == null) return null;
    final Map<String, String> identity;
    try {
      identity = await toolchainIdentity();
    } on Object catch (error) {
      log.logTrace('Could not identify the host Swift toolchain: $error');
      return null;
    }
    return XcodeSwiftRequirement.mismatchWithHint(
      xcodeMajor: xcodeMajor,
      swiftVersionOutput: identity['version'] ?? '',
      swiftPath: identity['swift'],
    );
  }

  Future<String?> _swiftTooOldForSdk(String bundle) => swiftTooOldForSdk(
    bundle,
    toolchainIdentity: sdkToolchainIdentity,
    log: runner.log,
    sdkPath: (bundle) =>
        repository.iosSdk(DarwinSdk(bundle), target: buildPlatform),
  );

  Future<List<DoctorCheck>> run() async {
    final deviceTools = await _deviceTools();
    if (deviceTools.status == DoctorStatus.failure) return [deviceTools];

    final checks = <DoctorCheck>[deviceTools, await _authentication()];
    try {
      checks.addAll(
        await devices(
          await deviceDiagnostics.devices(),
          osMajorVersion: deviceDiagnostics.osMajorVersion,
        ),
      );
    } on Object catch (error) {
      checks.add(DoctorCheck.warning('Device', 'Discovery failed: $error'));
    }
    return checks;
  }

  Future<DoctorCheck> _deviceTools() async {
    try {
      final executable = await deviceDiagnostics.resolveExecutable();
      return DoctorCheck.success('Device tools', 'Found', path: executable);
    } on Object catch (error) {
      return DoctorCheck.failure('Device tools', '$error');
    }
  }

  static Future<List<DoctorCheck>> devices(
    List<Device> found, {
    required Future<int?> Function(Device device) osMajorVersion,
  }) async {
    if (found.isEmpty) {
      return const [
        DoctorCheck.warning('Device', 'No connected iOS device found.'),
      ];
    }
    final resolveVersion = osMajorVersion;
    final checks = <DoctorCheck>[];
    for (final device in found) {
      checks.add(_deviceCheck(device, await resolveVersion(device)));
    }
    return checks;
  }

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

  Future<DoctorCheck> _authentication() async {
    final appleId = await _appleIdAuthentication();
    if (appleId != null) return appleId;
    return _appStoreConnectAuthentication();
  }

  Future<DoctorCheck?> _appleIdAuthentication() async {
    try {
      final session = await GrandSlamSessionStore(
        hostServices: appleHostServices,
      ).load();
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

  Future<DoctorCheck> _appStoreConnectAuthentication() async {
    final path = AscCredentials.defaultConfigPath(
      hostServices: appleHostServices,
    );
    if (!appleHostServices.host.fileSystem.file(path).existsSync()) {
      return const DoctorCheck.failure(
        'Authentication',
        'No credentials found. Run `xcross auth`.',
      );
    }
    try {
      final credentials = await AscCredentialsLoader(
        hostServices: appleHostServices,
      ).load(path: path);
      final client = AscClient(
        credentials,
        httpClient: createAppleHttpClient(),
      );
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
