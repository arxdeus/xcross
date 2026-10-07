import 'dart:async';
import 'dart:io';

import 'package:cli_kit/host/macos/macos_host.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:cli_kit/shared/process/process_models.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/host_symlink_capability.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_artifact_filesystem.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_checkout_attributes.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_checkout_link_creator.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_checkout_link_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_git_repository.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_graph.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_links.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_stamp.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';

@internal
final class CheckoutTestContext {
  CheckoutTestContext(
    Directory root,
    Process Function(CheckoutCommand) execute,
  ) {
    processes = RecordingCheckoutProcesses(execute);
    host = MacOSHost(
      environment: const {'CHECKOUT_FIXTURE': '1'},
      architecture: 'x64',
      currentDirectory: root.path,
      temporaryDirectory: root.path,
      processes: processes,
    );
    output = IOSink(CheckoutInputConsumer());
    runner = ProcessRunner(
      host,
      log: Log(output: const CheckoutLogOutput()),
      stdinStream: const Stream<List<int>>.empty(),
      stdoutSink: output,
      stderrSink: output,
    );
    fileSystem = PosixSwiftPmArtifactFileSystem(host);
    filesystem = SwiftPmFilesystem(
      host: host,
      runner: runner,
      artifactFileSystem: fileSystem,
    );
    stamps = SwiftPmCheckoutStampValidator(fileSystem: fileSystem);
    graph = SwiftPmCheckoutGraph(fileSystem: fileSystem);
    repository = SwiftPmGitRepository(
      runner: runner,
      fileSystem: fileSystem,
      filesystem: filesystem,
    );
    links = SwiftPmCheckoutLinks(
      runner: runner,
      fileSystem: fileSystem,
      stamps: stamps,
      attributes: const PosixSwiftPmCheckoutAttributes(),
      linkCreator: PosixSwiftPmCheckoutLinkCreator(fileSystem),
      policy: const PosixSwiftPmCheckoutGitPolicy(),
    );
    checkout = SwiftPmCheckout(
      runner: runner,
      fileSystem: fileSystem,
      symlinks: HostSymlinkCapability(host),
      stamps: stamps,
      graph: graph,
      repository: repository,
      links: links,
      fallback: PosixSwiftPmCheckoutFallback(
        fileSystem: fileSystem,
        filesystem: filesystem,
        graph: graph,
      ),
    );
  }
  late final MacOSHost host;
  late final ProcessRunner<MacOSHost> runner;
  late final RecordingCheckoutProcesses processes;
  late final PosixSwiftPmArtifactFileSystem fileSystem;
  late final SwiftPmFilesystem<MacOSHost> filesystem;
  late final SwiftPmCheckoutStampValidator stamps;
  late final SwiftPmCheckoutGraph graph;
  late final SwiftPmGitRepository<MacOSHost> repository;
  late final SwiftPmCheckoutLinks<MacOSHost> links;
  late final SwiftPmCheckout<MacOSHost> checkout;
  late final IOSink output;
}

@internal
final class CheckoutCommand {
  const CheckoutCommand(this.executable, this.arguments, this.environment);
  final String executable;
  final List<String> arguments;
  final Map<String, String>? environment;
}

@internal
final class RecordingCheckoutProcesses implements HostProcessInterface {
  @override
  ProcessExitDiagnostic describeExit(int exitCode) {
    if (exitCode < 0 || exitCode > 255) {
      throw StateError('Unexpected fixture exit: $exitCode');
    }
    return const ProcessExitDiagnostic(crashed: false, description: null);
  }

  RecordingCheckoutProcesses(this.execute);
  final Process Function(CheckoutCommand) execute;
  final List<CheckoutCommand> commands = [];
  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    final command = CheckoutCommand(
      executable,
      List.unmodifiable(arguments),
      environment,
    );
    commands.add(command);
    return execute(command);
  }

  @override
  Future<void> killTree(
    Process process, {
    Map<String, String>? environment,
    Map<String, String> executableOverrides = const {},
  }) async {
    process.kill();
  }

  @override
  Future<String?> findOnShellPath(
    String name, {
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
  }) async => '/fixture/$name';
}

@internal
final class CheckoutTestProcess implements Process {
  CheckoutTestProcess({
    this.code = 0,
    List<int> output = const [],
    List<int> error = const [],
  }) : stdout = Stream.value(output),
       stderr = Stream.value(error),
       input = CheckoutInputConsumer() {
    stdin = IOSink(input);
  }
  final int code;
  final CheckoutInputConsumer input;
  @override
  late final IOSink stdin;
  @override
  final Stream<List<int>> stdout;
  @override
  final Stream<List<int>> stderr;
  @override
  Future<int> get exitCode async => code;
  @override
  int get pid => 42;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

@internal
final class CheckoutInputConsumer implements StreamConsumer<List<int>> {
  final List<int> bytes = [];
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      bytes.addAll(chunk);
    }
  }

  @override
  Future<void> close() async {}
}

@internal
final class CheckoutLogOutput implements LogOutput {
  const CheckoutLogOutput();
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
