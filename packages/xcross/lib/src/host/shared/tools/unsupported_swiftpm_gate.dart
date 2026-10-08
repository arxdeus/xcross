import 'package:meta/meta.dart';
import 'package:xcross/src/shared/tools/swiftpm_gate_operation.dart';

@internal
final class UnsupportedSwiftPmGate implements SwiftPmGateOperation {
  const UnsupportedSwiftPmGate(this.hostName);
  final String hostName;
  @override
  Future<void> run(List<String> arguments) => Future.error(
    UnsupportedError(
      'SwiftPM feasibility evidence is supported only on Windows, not $hostName',
    ),
  );
}
