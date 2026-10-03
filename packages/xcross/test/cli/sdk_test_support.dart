import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:xcross/src/cli/basic/sdk_install.dart';

import 'package:xcross/src/host/shared/sdk/preserved_sdk_archive_links.dart';
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
    runner = ProcessRunner(host, log: log);
    repository = DarwinSdkRepository(host, log: log);
  }
  late final MacOSHost host;
  late final SdkFixtureLogOutput output;
  late final Log log;
  late final ProcessRunner<MacOSHost> runner;
  late final DarwinSdkRepository<MacOSHost> repository;

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
