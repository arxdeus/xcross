import 'package:xcross/src/shared/flutter/swiftpm/gate_mode.dart';

typedef SwiftPmGateVerify = Future<bool> Function({required SwiftPmGateMode mode, required String root, required String platformIdentity, required String toolchainIdentity, required String sdkIdentity});

abstract interface class SwiftPmGateOperation {
  Future<void> run(List<String> arguments);
}

abstract interface class SwiftPmGateRuntimeLoader {
  Future<SwiftPmGateServices> loadSwiftPmGate();
}

final class SwiftPmGateServices {
  const SwiftPmGateServices({required this.cacheRoot, required this.platformIdentity, required this.toolchainIdentity, required this.sdkIdentity, required this.verify});
  final String cacheRoot;
  final String platformIdentity;
  final Future<String> Function() toolchainIdentity;
  final Future<String> Function() sdkIdentity;
  final SwiftPmGateVerify verify;
}
