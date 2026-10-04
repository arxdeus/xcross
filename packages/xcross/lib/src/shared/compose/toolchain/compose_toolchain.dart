import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/compose/compose_host.dart';
import 'package:xcross/src/target/shared/compose/compose_target.dart';

@internal
final class ComposeToolchain<T extends PlatformHostInterface> {
  const ComposeToolchain({
    required this.target,
    required this.runner,
    required this.log,
    required this.kotlinHome,
    required this.konanCache,
    required this.konancExecutable,
    required this.javaHome,
    required this.javaExecutable,
    required this.gradleExecutable,
    required this.swiftc,
    required this.clang,
    required this.ld64Lld,
    required this.darwinSdkPath,
    required this.darwinSdkBundle,
  });

  final ComposeTarget<T> target;
  final ProcessRunner<T> runner;
  final Log log;
  ComposeHost<T> get host => target.toolchainHost;
  final String kotlinHome;
  final String konanCache;
  final String konancExecutable;
  final String javaHome;
  final String javaExecutable;
  final String gradleExecutable;
  final String swiftc;
  final String clang;
  final String ld64Lld;

  /// The resolved `iPhoneOS(.\d+)?.sdk` leaf, e.g.
  /// `.../xcross-darwin.artifactbundle/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk`.
  ///
  /// This is `-isysroot`/`targetSysRoot`, a specific SDK version, not the
  /// artifact bundle. Use [darwinSdkBundle] for anything that needs to reach
  /// other bundle contents (the Xcode toolchain, compiler-rt libraries).
  final String darwinSdkPath;

  /// Root of the `xcross-darwin.artifactbundle` Swift SDK artifact bundle
  /// that [darwinSdkPath] was resolved from, e.g.
  /// `Developer/Toolchains/XcodeDefault.xctoolchain/...` and
  /// `Developer/Platforms/iPhoneOS.platform/Developer/SDKs/<version>.sdk`
  /// both live under this root.
  final String darwinSdkBundle;

  List<String> get gradleInvocation => [gradleExecutable];

  List<String> konancInvocation(List<String> arguments) => [
    konancExecutable,
    ...arguments,
  ];
}
