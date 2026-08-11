import 'package:xcross/src/compose/toolchain/compose_host.dart';

final class ComposeToolchain {
  const ComposeToolchain({
    required this.host,
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
  });

  final ComposeHost host;
  final String kotlinHome;
  final String konanCache;
  final String konancExecutable;
  final String javaHome;
  final String javaExecutable;
  final String gradleExecutable;
  final String swiftc;
  final String clang;
  final String ld64Lld;
  final String darwinSdkPath;

  List<String> get gradleInvocation =>
      host.invokeExecutable(gradleExecutable, const []);

  List<String> konancInvocation(List<String> arguments) =>
      host.invokeExecutable(konancExecutable, arguments);
}
