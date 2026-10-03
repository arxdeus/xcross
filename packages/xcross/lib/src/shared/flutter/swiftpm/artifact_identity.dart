import 'dart:convert';
import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/sdk_identity.dart';
import 'package:xcross/src/shared/flutter/swiftpm/toolchain.dart';

final class SwiftPmArtifactIdentity {
const SwiftPmArtifactIdentity({required this.platform,required this.toolchain,required this.sdk});
final String platform;
final String toolchain;
final String sdk;
}
abstract interface class SwiftPmArtifactIdentities {
Future<SwiftPmArtifactIdentity> resolve();
}
final class SwiftPmArtifactIdentityResolver<T extends PlatformHostInterface> implements SwiftPmArtifactIdentities {
SwiftPmArtifactIdentityResolver({required this.repository,required this.sdkIdentity,required this.hostPolicy,required this.toolchain});
final DarwinSdkRepository<T> repository;
final SwiftPmSdkIdentity sdkIdentity;
final SwiftPmHostPolicy hostPolicy;
final SwiftPmToolchain<T> toolchain;
@override
Future<SwiftPmArtifactIdentity> resolve() async {
final sdk=repository.current();
return SwiftPmArtifactIdentity(platform:sdkIdentity.platformIdentity,sdk:jsonEncode(sdk==null?const <String,Object>{}:await sdkIdentity.sdkBuildIdentity(sdk.swiftSdkPath)),toolchain:jsonEncode(await hostPolicy.buildToolchainIdentity(toolchain,sdk)));
}
}
