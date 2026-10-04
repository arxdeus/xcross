import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_simulator.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/sdk/sdk_metadata_platform.dart';

final class SimulatorSdkMetadataPlatform<T extends PlatformHostInterface>
    implements SdkMetadataPlatformInterface<T> {
  const SimulatorSdkMetadataPlatform();
  @override
  SimulatorBuildPlatform get buildPlatform => const SimulatorBuildPlatform();
  @override
  String? resolveSdkRoot(DarwinSdkRepository<T> repository, DarwinSdk sdk) {
    final host = repository.host;
    final platform = host.paths.context.join(
      sdk.bundle,
      'Developer',
      'Platforms',
      'iPhoneSimulator.platform',
      'Developer',
      'SDKs',
    );
    if (!host.fileSystem.directory(platform).existsSync()) return null;
    final root = repository.iosSdk(sdk, target: buildPlatform);
    if (!RegExp('[0-9]').hasMatch(host.paths.context.basename(root))) {
      throw XcrossError(
        'The extracted Xcode archive did not contain a versioned iPhoneSimulator SDK.',
      );
    }
    if (!repository.isValidSimulatorSlice(sdk.bundle)) {
      throw XcrossError(
        'The extracted Xcode archive contains an incomplete iPhoneSimulator SDK or Swift resources.',
      );
    }
    return root;
  }
}
