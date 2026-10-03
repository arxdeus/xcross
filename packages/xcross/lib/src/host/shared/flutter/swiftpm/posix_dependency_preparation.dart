import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/shared/flutter/swiftpm/dependency_preparation.dart';

final class PosixSwiftPmDependencyPreparation<T extends PlatformHostInterface>
    implements SwiftPmDependencyPreparation<T> {
  const PosixSwiftPmDependencyPreparation();
  @override
  Future<void> prepare(SwiftPmDependencyCommand command) async {}
  @override
  Future<void> materializeClone(
    String destination,
    String git,
    String vendorDir,
  ) async {}
  @override
  Future<({Map<String, String> pins, Map<String, String> originals})>
  bootstrapPinned(SwiftPmPinnedDependencyCommand command) async =>
      (pins: <String, String>{}, originals: <String, String>{});
  @override
  Future<void> prepareArtifacts(
    String packageRoot,
    String store,
    String fallback, {
    required bool capability,
  }) async {}
  @override
  Future<bool> recoverArtifacts(
    SwiftPmDependencyArtifactCommand command,
  ) async => false;
}
