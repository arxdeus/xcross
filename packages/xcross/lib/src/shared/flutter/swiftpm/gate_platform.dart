import 'package:cli_kit/cli_kit.dart';
import 'package:xcross/src/flutter/build/internal/swiftpm_gate_evidence.dart';
import 'package:xcross/src/shared/flutter/swiftpm/gate_execution.dart';

abstract interface class SwiftPmGatePlatform {
  Future<String?> volumeIdentity<T extends PlatformHostInterface>(
    SwiftPmGateExecution<T> execution,
    String path,
  );
  Future<bool> createProofAlias<T extends PlatformHostInterface>(
    SwiftPmGateExecution<T> execution,
    String alias,
    String target,
  );
  Future<bool> verifyAlias<T extends PlatformHostInterface>(
    SwiftPmGateExecution<T> execution,
    String alias,
    String target,
  );
  Future<bool> probe<T extends PlatformHostInterface>(
    SwiftPmGateExecution<T> execution, {
    required SwiftPmGateMode mode,
    required String root,
    required String toolchainIdentity,
    required String sdkIdentity,
    SwiftPmGateRun? run,
  });
}
