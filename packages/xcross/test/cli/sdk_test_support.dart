import 'dart:async';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:xcross/src/host/shared/sdk/preserved_sdk_archive_links.dart';
import 'package:xcross/src/shared/cli/basic/sdk_install.dart';
import 'package:xcross/src/target/iphone/sdk/iphone_sdk_metadata_platform.dart';
import 'package:xcross/src/target/simulator/sdk/simulator_sdk_metadata_platform.dart';

export 'package:xcross/src/host/shared/sdk/preserved_sdk_archive_links.dart';
export 'package:xcross/src/host/windows/sdk/materialized_sdk_archive_links.dart';
export 'package:xcross/src/target/iphone/sdk/iphone_sdk_metadata_platform.dart';
export 'package:xcross/src/target/simulator/sdk/simulator_sdk_metadata_platform.dart';

final class SdkTestContext {
  SdkTestContext() {
    host = MacOSHost();
    output = SdkFixtureLogOutput();
    log = Log(output: output);
    processOutput.stream.listen((_) {});
    processError.stream.listen((_) {});
    stdoutSink = IOSink(processOutput.sink);
    stderrSink = IOSink(processError.sink);
    runner = ProcessRunner(
      host,
      log: log,
      stdinStream: const Stream<List<int>>.empty(),
      stdoutSink: stdoutSink,
      stderrSink: stderrSink,
    );
    repository = DarwinSdkRepository(host, log: log);
  }
  late final MacOSHost host;
  late final SdkFixtureLogOutput output;
  late final Log log;
  late final ProcessRunner<MacOSHost> runner;
  late final DarwinSdkRepository<MacOSHost> repository;
  final StreamController<List<int>> processOutput =
      StreamController<List<int>>();
  final StreamController<List<int>> processError =
      StreamController<List<int>>();
  late final IOSink stdoutSink;
  late final IOSink stderrSink;

  Future<void> close() async {
    await Future.wait([stdoutSink.close(), stderrSink.close()]);
  }

  SdkInstall<MacOSHost> installer({SdkArchiveLinksInterface? links}) =>
      SdkInstall(
        runner,
        repository,
        links: links ?? PreservedSdkArchiveLinks(host),
        swiftInstallGuidance: 'Use the isolated fixture Swift toolchain.',
        swiftBuildTools: const ['swift', 'swiftc'],
        metadataPlatforms: const [
          IPhoneSdkMetadataPlatform<MacOSHost>(),
          SimulatorSdkMetadataPlatform<MacOSHost>(),
        ],
      );
}

final class SdkFixtureLogOutput implements LogOutput {
  final List<String> messages = [];
  @override
  bool get supportsAnsi => false;
  @override
  int get terminalColumns => 80;
  @override
  void stdout(String message) => messages.add(message);
  @override
  void stderr(String message) => messages.add(message);
  @override
  void write(String message) => messages.add(message);
}
