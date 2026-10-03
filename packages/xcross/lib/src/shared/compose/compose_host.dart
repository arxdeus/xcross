import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/compose/build/process_invocation.dart';

abstract interface class ComposeHost<T extends PlatformHostInterface> {
  T get host;
  String get classifier;
  String get runningExecutable;
  String get konanTarget;
  String hostArtifact(String version);
  List<String> installationArtifacts(String version);
  String konancExecutable(String kotlinHome);
  String javaExecutable(String javaHome);
  String gradleWrapper(String projectRoot);
  bool supportsJavaArchitecture(String architecture);
  ProcessInvocation invocation(String executable, List<String> arguments);
  List<String> compilerArguments(
    List<String> launcher,
    List<String> arguments,
    String Function() writeArgumentFile,
  );
  bool canCacheLibraryNames(Iterable<String> names);
  List<File> shimFingerprintFiles(String runningExecutable);
  Future<void> writeShim(
    String path,
    String tool,
    String variable,
    String runningExecutable,
    void Function(String) makeExecutable,
  );
  String resolveAppleTool(
    String directory,
    String name,
    Iterable<String> searchPath, {
    String? nativeFallback,
  });
}
