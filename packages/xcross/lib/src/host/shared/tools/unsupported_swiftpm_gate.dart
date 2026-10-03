import 'package:xcross/src/shared/tools/swiftpm_gate_operation.dart';

final class UnsupportedSwiftPmGate implements SwiftPmGateOperation {
  const UnsupportedSwiftPmGate(this.hostName);
  final String hostName;
  @override
  Future<void> run(List<String> arguments) async {
    throw UnsupportedError('SwiftPM feasibility evidence is supported only on Windows, not $hostName');
  }
}
