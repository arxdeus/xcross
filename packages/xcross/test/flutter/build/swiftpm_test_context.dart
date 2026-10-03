import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/internal/apple_tool_shims.dart';
import 'package:xcross/src/host/linux/flutter/swiftpm/swiftpm_host_policy.dart';
import 'package:xcross/src/host/macos/flutter/native_host_tools.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_artifact_filesystem.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_checkout_attributes.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_checkout_link_creator.dart';
import 'package:xcross/src/host/windows/flutter/native_host_tools.dart';
import 'package:xcross/src/host/windows/flutter/swiftpm/swiftpm_host_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/runtime.dart';
import 'package:xcross/src/shared/flutter/swiftpm/sdk_identity.dart';
import 'package:xcross/src/target/iphone/flutter/iphone_flutter_target.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';
import 'package:xcross/src/target/simulator/flutter/simulator_flutter_target.dart';

SwiftPmRuntime<MacOSHost> testSwiftPmRuntime({
  SwiftPmHostPolicy? hostPolicy,
  FlutterTargetBuildPolicy<MacOSHost> Function(MacOSHost)? targetPolicy,
  Map<String, String>? environment,
  SwiftPmSdkIdentity? sdkIdentity,
}) {
  final host = MacOSHost(
    environment: environment ?? Platform.environment,
    currentDirectory: Directory.current.path,
    temporaryDirectory: Directory.systemTemp.path,
  );
  final runner = ProcessRunner(host, log: testSwiftPmLog);
  final repository = DarwinSdkRepository(
    host,
    log: testSwiftPmLog,
    installBundle: p.join(Directory.systemTemp.path, 'xcross-unit-no-sdk-$pid'),
  );
  final toolchain = DarwinToolchainResolver(
    runner,
    MacOSDarwinToolchainLocations(host),
  );
  final policy =
      targetPolicy?.call(host) ?? IPhoneFlutterTarget(IPhoneTarget(host));
  final tools = AppleToolShimResolver(
    policy.target,
    runner,
    repository,
    toolchain,
    hostTools: MacOSNativeHostTools(host, runner),
    executable: Platform.resolvedExecutable,
  );
  return SwiftPmRuntime(
    policy,
    runner,
    repository,
    toolchain,
    tools,
    hostPolicy ?? const LinuxSwiftPmHostPolicy(),
    PosixSwiftPmArtifactFileSystem(host),
    sdkIdentity ?? const TestSwiftPmSdkIdentity(),
  );
}

SwiftPmRuntime<WindowsHost> testWindowsSwiftPmRuntime({
  Map<String, String>? environment,
  SwiftPmSdkIdentity? sdkIdentity,
  FlutterTargetBuildPolicy<WindowsHost> Function(WindowsHost)? targetPolicy,
}) {
  final native = MacOSHost(
    environment: Platform.environment,
    currentDirectory: Directory.current.path,
    temporaryDirectory: Directory.systemTemp.path,
  );
  final host = WindowsHost(
    environment: environment ?? Platform.environment,
    architecture: 'x64',
    paths: _WindowsTestPaths(native.paths, environment ?? Platform.environment),
    fileSystem: native.fileSystem,
    processes: native.processes,
  );
  final runner = ProcessRunner(host, log: testSwiftPmLog);
  final repository = DarwinSdkRepository(
    host,
    log: testSwiftPmLog,
    installBundle: p.join(Directory.systemTemp.path, 'xcross-unit-no-sdk-$pid'),
  );
  final toolchain = DarwinToolchainResolver(
    runner,
    WindowsDarwinToolchainLocations(host),
  );
  final policy =
      targetPolicy?.call(host) ?? IPhoneFlutterTarget(IPhoneTarget(host));
  final tools = AppleToolShimResolver(
    policy.target,
    runner,
    repository,
    toolchain,
    hostTools: WindowsNativeHostTools(host, runner),
    executable: Platform.resolvedExecutable,
  );
  return SwiftPmRuntime(
    policy,
    runner,
    repository,
    toolchain,
    tools,
    WindowsSwiftPmHostPolicy(runner,attributes:const PosixSwiftPmCheckoutAttributes(), checkoutLinks:const PosixSwiftPmCheckoutLinkCreator()),
    PosixSwiftPmArtifactFileSystem(host),
    sdkIdentity ?? const TestSwiftPmSdkIdentity(),
  );
}

final class _WindowsTestPaths implements HostPathsInterface {
  _WindowsTestPaths(this.native, Map<String,String> environment) : windows = WindowsPaths(environment:environment, context:native.context);
  final WindowsPaths windows;
  final HostPathsInterface native;
  @override
  p.Context get context => native.context;
  @override
  String get configRoot => native.configRoot;
  @override
  String get cacheRoot => windows.cacheRoot;
  @override
  String get temporaryRoot => native.temporaryRoot;
  @override
  String ioPath(String path) => native.ioPath(path);
  @override
  String pathKey(String path) => native.pathKey(path).toLowerCase();
  @override
  String executableName(String name, {String extension = '.exe'}) =>
      name.endsWith(extension) ? name : '$name$extension';
}

SwiftPmRuntime<MacOSHost> testSimulatorSwiftPmRuntime() => testSwiftPmRuntime(
  targetPolicy: (host) => SimulatorFlutterTarget(SimulatorTarget(host)),
);

final class TestSwiftPmSdkIdentity implements SwiftPmSdkIdentity {
  const TestSwiftPmSdkIdentity({this.platformIdentity = 'test-platform'});
  @override
  final String platformIdentity;
  @override
  Future<Map<String, Object>> sdkBuildIdentity(String root) async => const {};
  @override
  Future<Map<String, Object>> hostToolchainIdentity() async => const {};
  @override
  Future<Map<String, Object>> swiftPmBuildToolchainIdentity({
    required String cCompilerPath,
    required String cxxCompilerPath,
    required String linkerPath,
    required String librarianPath,
  }) async => const {};
  @override
  Future<String?> hostToolchainMismatch(String root) async => null;
  @override
  String mismatchGuidance(String? detail) =>
      'After switching Swift, run xcross sdk install. ${detail ?? ''}';
}

SwiftPmRuntime<WindowsHost> testWindowsSimulatorSwiftPmRuntime() =>
    testWindowsSwiftPmRuntime(
      targetPolicy: (host) => SimulatorFlutterTarget(SimulatorTarget(host)),
    );

final testSwiftPmLog = Log(output: const _TestLogOutput());

final class _TestLogOutput implements LogOutput {
  const _TestLogOutput();
  @override
  bool get supportsAnsi => false;
  @override
  int get terminalColumns => 80;
  @override
  void stdout(String message) {}
  @override
  void stderr(String message) {}
  @override
  void write(String message) {}
}
