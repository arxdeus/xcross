import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/swiftpm/gate_mode.dart';
import 'package:xcross/src/shared/tools/swiftpm_gate_operation.dart';

final class WindowsSwiftPmGate implements SwiftPmGateOperation {
  const WindowsSwiftPmGate(this.loader);
  final SwiftPmGateRuntimeLoader loader;

  @override
  Future<void> run(List<String> arguments) async {
    if (arguments.length != 2 || arguments.first != 'record') {
      throw ArgumentError('usage: swiftpm_gate_evidence record <mode>');
    }
    final mode = SwiftPmGateMode.values.singleWhere(
      (candidate) => candidate.name == arguments[1],
    );
    final services = await loader.loadSwiftPmGate();
    if (services.cacheRoot.isEmpty)
      throw StateError('XCROSS_CACHE_DIR is required');
    final passed = await services.verify(
      root: p.join(services.cacheRoot, 'swiftpm', 'gate-evidence-v2'),
      mode: mode,
      platformIdentity: services.platformIdentity,
      toolchainIdentity: await services.toolchainIdentity(),
      sdkIdentity: await services.sdkIdentity(),
    );
    if (!passed) throw StateError('${mode.name} feasibility probe failed');
  }
}
