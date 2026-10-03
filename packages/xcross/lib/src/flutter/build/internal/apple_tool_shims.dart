import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/host/shared/flutter/apple_tool_shim_renderer.dart';
import 'package:xcross/src/host/shared/flutter/native_host_tools.dart';

@immutable
final class OtoolConfig {
  const OtoolConfig(this.executable, {required this.usesObjdump});

  final String executable;
  final bool usesObjdump;
}

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
    if (declarative) {
      throw FlutterBuildError(
        'xcrun not configured. Set tools.xcrun or configure an xcross launcher with a bundled xcrun sibling.',
      );
    }
    final sibling = host.paths.context.join(
      host.paths.context.dirname(executable),
      host.paths.executableName('xcrun'),
    );
    if (host.fileSystem.file(sibling).existsSync()) return sibling;
    return runner.locateTool('xcrun');
  }

  Future<HostCompiler> resolveHostCompiler(String clang) =>
      hostTools.compiler(clang);
  Future<String?> resolveNativeAssetToolForwarder(
    String executable, {
    String? launcher,
  }) => hostTools.forwarder(executable, launcher ?? this.launcher);
  Future<String> _locateArchiver(String clang) async {
    final beside = host.paths.context.join(
      host.paths.context.dirname(clang),
      host.paths.executableName('llvm-ar'),
    );
    if (host.fileSystem.file(beside).existsSync()) return beside;
    return locateLlvmTool('llvm-ar');
  }

  Future<String?> findLlvmTool(String name) =>
      toolchain.locateLlvmTool(host.paths.executableName(name));
  Future<String> locateLlvmTool(String name) async {
    final tool = await findLlvmTool(name);
    if (tool != null) return tool;
    throw FlutterBuildError("Could not find '$name'. Install LLVM and retry.");
  }

  Future<OtoolConfig?> resolveOtool() => resolveOtoolWith(find: findLlvmTool);
}

Future<OtoolConfig?> resolveOtoolWith({
  required Future<String?> Function(String name) find,
}) async {
  final otool = await find('llvm-otool');
  if (otool != null) return OtoolConfig(otool, usesObjdump: false);
  final objdump = await find('llvm-objdump');
  return objdump == null ? null : OtoolConfig(objdump, usesObjdump: true);
}

Future<OtoolConfig?> resolveOtool({
  required Future<String?> Function(String name) find,
}) => resolveOtoolWith(find: find);

FlutterBuildError missingNativeAssetToolForwarderError() => FlutterBuildError(
  "Windows native assets need the native xcross.exe binary: Flutter's "
  'native_toolchain_c only accepts a C compiler named clang.exe, so xcross '
  'installs copies of xcross.exe as clang.exe/cc.exe/ar.exe/ld.exe tool '
  'aliases. No xcross.exe was found (this happens when xcross runs through '
  '`dart run` or a `dart pub global` .bat launcher). Install the xcross '
  'release binary, add its directory to PATH, or set the xcross launcher path '
  'in `xcross config`.',
);

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
