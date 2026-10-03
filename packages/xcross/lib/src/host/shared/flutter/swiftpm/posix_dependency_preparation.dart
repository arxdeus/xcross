import 'package:xcross/src/shared/flutter/swiftpm/binary_recovery.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:xcross/src/shared/flutter/swiftpm/dependency_preparation.dart';
final class PosixSwiftPmDependencyPreparation<T extends PlatformHostInterface> implements SwiftPmDependencyPreparation<T> {
const PosixSwiftPmDependencyPreparation();
@override
Future<void> prepare(SwiftPmDependencyPreparationRequest<T> request) async {}
@override
Future<void> materializeClone(SwiftPmCheckout<T> checkout,String destination,String git,String vendorDir) async {}
@override
Future<({Map<String,String> pins,Map<String,String> originals})> bootstrapPinned(SwiftPmPinnedDependencyRequest<T> request) async => (pins:<String,String>{},originals:<String,String>{});
@override
Future<void> prepareArtifacts(SwiftPmBinaryRecovery<T> recovery,String packageRoot,String store,String fallback,bool capability) async {}
@override
Future<bool> recoverArtifacts(SwiftPmDependencyArtifactRecoveryRequest<T> request) async =>false;
}
