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

final sdkFixtureHost = MacOSHost();
final sdkFixtureRunner = ProcessRunner(sdkFixtureHost);
final sdkFixtureRepository = DarwinSdkRepository(sdkFixtureHost);

SdkInstall<MacOSHost> sdkFixtureInstaller({SdkArchiveLinksInterface? links}) =>
    SdkInstall(
      sdkFixtureRunner,
      sdkFixtureRepository,
      links: links ?? PreservedSdkArchiveLinks(sdkFixtureHost),
      swiftInstallGuidance: 'Use the isolated fixture Swift toolchain.',
      swiftBuildTools: const ['swift', 'swiftc'],
      metadataPlatforms: const [
        IPhoneSdkMetadataPlatform<MacOSHost>(),
        SimulatorSdkMetadataPlatform<MacOSHost>(),
      ],
    );
