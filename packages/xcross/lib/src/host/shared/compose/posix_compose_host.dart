import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/compose/build/process_invocation.dart';
import 'package:xcross/src/shared/compose/compose_host.dart';

@internal
abstract class PosixComposeHost<T extends PlatformHostInterface>
    implements ComposeHost<T> {
  const PosixComposeHost(this.host);
  @override
  final T host;
  @override
  String get runningExecutable => '';
  @override
  String hostArtifact(String version) =>
      'kotlin-native-prebuilt-$version-$classifier.tar.gz';
  @override
  String konancExecutable(String home) => p.join(home, 'bin', 'konanc');
  @override
  String javaExecutable(String home) => p.join(home, 'bin', 'java');
  @override
  String gradleWrapper(String root) => p.join(root, 'gradlew');
  @override
  ProcessInvocation invocation(String executable, List<String> arguments) =>
      ProcessInvocation(executable: executable, arguments: arguments);
  @override
  List<String> compilerArguments(
    List<String> launcher,
    List<String> arguments,
    String Function() writeArgumentFile,
  ) => [...launcher, ...arguments];
  @override
  bool canCacheLibraryNames(Iterable<String> names) => true;
  @override
  List<File> shimFingerprintFiles(String runningExecutable) => const [];
  @override
  Future<void> writeShim(
    String path,
    String tool,
    String variable,
    String runningExecutable,
    void Function(String) makeExecutable,
  ) async {
    final prefix = tool == 'dsymutil'
        ? 'if [ ! -x "\$$variable" ]; then exit 0; fi\n'
        : '';
    host.fileSystem
        .file(path)
        .writeAsStringSync(
          '#!/bin/sh\n$prefix'
          'exec "\$$variable" "\$@"\n',
        );
    makeExecutable(path);
  }

  @override
  String resolveAppleTool(
    String directory,
    String name,
    Iterable<String> searchPath, {
    String? nativeFallback,
  }) => siblingOrOnPath(directory, name, searchPath, host.fileSystem);
}

@internal
String siblingOrOnPath(
  String directory,
  String name,
  Iterable<String> searchPath,
  HostFileSystemInterface files,
) {
  final sibling = p.join(directory, name);
  if (files.file(sibling).existsSync()) return sibling;
  for (final entry in searchPath) {
    if (entry.isEmpty) continue;
    final candidate = p.join(entry, name);
    if (files.file(candidate).existsSync()) return candidate;
  }
  return sibling;
}

@internal
bool isX64Architecture(String architecture) => const [
  'x64',
  'x86_64',
  'amd64',
].contains(architecture.trim().toLowerCase());
@internal
bool isArm64Architecture(String architecture) =>
    const ['arm64', 'aarch64'].contains(architecture.trim().toLowerCase());
