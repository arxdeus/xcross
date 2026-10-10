import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk_repository.dart';
import 'package:darwin_sdk_kit/shared/toolchain/darwin_toolchain_resolver.dart';
import 'package:darwin_sdk_kit/target/shared/ios_build_platform.dart';
import 'package:darwin_sdk_kit/target/shared/ios_target.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/host/shared/flutter/apple_tool_shim_renderer.dart';
import 'package:xcross/src/host/shared/flutter/native_host_tools.dart';
import 'package:xcross/src/shared/flutter/errors.dart';

@internal
@immutable
final class OtoolConfig {
  const OtoolConfig(this.executable, {required this.usesObjdump});

  final String executable;
  final bool usesObjdump;
}

@internal
@immutable
final class AppleToolShimConfig {
  const AppleToolShimConfig({
    required this.iosSdk,
    required this.clang,
    required this.hostCompiler,
    required this.archiver,
    required this.linker,
    required this.lipo,
    required this.otool,
    required this.installNameTool,
    required this.xcrun,
    required this.deploymentTarget,
    required this.target,
    this.hostCompilerArguments = const [],
  });

  final String iosSdk;
  final String clang;
  final String hostCompiler;
  final List<String> hostCompilerArguments;
  final String archiver;
  final String linker;
  final String lipo;
  final OtoolConfig? otool;
  final String? installNameTool;
  final String xcrun;
  final String deploymentTarget;
  final IosBuildPlatformInterface target;
}

@internal
final class AppleToolShimResolver<T extends PlatformHostInterface> {
  AppleToolShimResolver(
    this.target,
    this.runner,
    this.repository,
    this.toolchain, {
    required this.executable,
    required this.hostTools,
    this.launcher,
    this.xcrun,
    this.openAppleMacrosServer,
    this.declarative = false,
  }) {
    if (!identical(host, runner.host) ||
        !identical(host, repository.host) ||
        !identical(host, toolchain.host) ||
        !identical(host, hostTools.host)) {
      throw ArgumentError(
        'Apple tool resolution requires one coherent host instance',
      );
    }
  }
  final IosTarget<T> target;
  T get host => target.host;
  final ProcessRunner<T> runner;
  final DarwinSdkRepository<T> repository;
  final DarwinToolchainResolver<T> toolchain;
  final NativeHostTools<T> hostTools;
  final String? launcher;
  final String? xcrun;
  final String? openAppleMacrosServer;
  final bool declarative;
  final String executable;

  Future<AppleToolShimConfig> resolve(String deploymentTarget) async {
    final sdk = repository.current();
    if (sdk == null) {
      throw FlutterBuildError(
        'Native assets require an installed Darwin SDK. Run `xcross sdk install <Xcode.xip|Xcode.app>` first.',
      );
    }
    final iosSdk = repository.iosSdk(sdk, target: target.buildPlatform);
    final clang = await toolchain.resolveDarwinClang(iosSdk);
    final compiler = await resolveHostCompiler(clang);
    return AppleToolShimConfig(
      iosSdk: iosSdk,
      clang: clang,
      hostCompiler: compiler.executable,
      hostCompilerArguments: compiler.arguments,
      archiver: await _locateArchiver(clang),
      linker: await toolchain.resolveLd64Lld(),
      lipo: await locateLlvmTool('llvm-lipo'),
      otool: await resolveOtool(),
      installNameTool: await findLlvmTool('llvm-install-name-tool'),
      xcrun: await resolveXcrun(),
      deploymentTarget: deploymentTarget,
      target: target.buildPlatform,
    );
  }

  Future<String> resolveXcrun({String? launcher}) async {
    if (xcrun case final configured? when configured.isNotEmpty) {
      return configured;
    }
    final effectiveLauncher = this.launcher ?? launcher;
    if (effectiveLauncher != null) {
      final sibling = host.paths.context.join(
        host.paths.context.dirname(effectiveLauncher),
        host.paths.executableName('xcrun'),
      );
      if (host.fileSystem.file(sibling).existsSync()) return sibling;
    }
    final sibling = host.paths.context.join(
      host.paths.context.dirname(executable),
      host.paths.executableName('xcrun'),
    );
    if (host.fileSystem.file(sibling).existsSync()) return sibling;
    if (declarative) {
      throw FlutterBuildError(
        'xcrun not configured. Set tools.xcrun or configure an xcross launcher with a bundled xcrun sibling.',
      );
    }
    final located = await runner.locateTool('xcrun');
    return located;
  }

  Future<HostCompiler> resolveHostCompiler(String clang) =>
      hostTools.compiler(clang);
  Future<String> resolveNativeAssetToolForwarder(
    String executable, {
    String? launcher,
  }) => hostTools.forwarder(executable, launcher ?? this.launcher);
  Future<String> _locateArchiver(String clang) async {
    final beside = host.paths.context.join(
      host.paths.context.dirname(clang),
      host.paths.executableName('llvm-ar'),
    );
    if (host.fileSystem.file(beside).existsSync()) return beside;
    final llvmAr = await locateLlvmTool('llvm-ar');
    return llvmAr;
  }

  Future<String?> findLlvmTool(String name) =>
      toolchain.locateLlvmTool(host.paths.executableName(name));
  Future<String> locateLlvmTool(String name) async {
    final tool = await findLlvmTool(name);
    if (tool != null) return tool;
    throw FlutterBuildError("Could not find '$name'. Install LLVM and retry.");
  }

  Future<OtoolConfig?> resolveOtool() async {
    final otool = await findLlvmTool('llvm-otool');
    if (otool != null) return OtoolConfig(otool, usesObjdump: false);
    final objdump = await findLlvmTool('llvm-objdump');
    return objdump == null ? null : OtoolConfig(objdump, usesObjdump: true);
  }
}

@internal
Future<void> installAppleToolShims<T extends PlatformHostInterface>(
  String directory,
  AppleToolShimConfig config, {
  required AppleToolShimRenderer<T> renderer,
  String? toolForwarderExecutable,
}) => renderer.install(
  directory,
  config,
  toolForwarderExecutable: toolForwarderExecutable,
);
