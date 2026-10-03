import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/host/shared/tools/unsupported_swiftpm_gate.dart';
import 'package:xcross/src/host/windows/tools/windows_swiftpm_gate.dart';
import 'package:xcross/src/shared/tools/swiftpm_gate_operation.dart';
import 'package:xcross/src/shared/flutter/swiftpm/gate_mode.dart';

void main() {
  test('Windows validates arguments before runtime loading', () async {
    final loader = _Loader();
    await expectLater(WindowsSwiftPmGate(loader).run(['install']), throwsArgumentError);
    await expectLater(WindowsSwiftPmGate(loader).run(['record', 'unknown']), throwsStateError);
    expect(loader.loads, 0);
  });

  test('Windows passes exact mode root and identities to concrete probe', () async {
    final loader = _Loader();
    await WindowsSwiftPmGate(loader).run(['record', 'packageLocalArtifact']);
    expect(loader.loads, 1);
    expect(loader.request, (mode: SwiftPmGateMode.packageLocalArtifact, root: p.join('/fixture/cache', 'swiftpm', 'gate-evidence-v2'), platform: 'windows-fixture', toolchain: '{"toolchain":"fixture"}', sdk: '{"sdk":"fixture"}'));
  });

  test('Windows preserves failed feasibility outcome', () async {
    final loader = _Loader()..passed = false;
    await expectLater(WindowsSwiftPmGate(loader).run(['record', 'swiftPmArtifact']), throwsA(predicate((Object error) => error.toString().contains('swiftPmArtifact feasibility probe failed'))));
  });

  for (final host in ['linux', 'macos']) {
    test('$host rejects evidence recording before runtime work', () async {
      await expectLater(UnsupportedSwiftPmGate(host).run(['record', 'swiftPmArtifact']), throwsUnsupportedError);
    });
  }
}

final class _Loader implements SwiftPmGateRuntimeLoader {
  int loads = 0;
  bool passed = true;
  ({SwiftPmGateMode mode, String root, String platform, String toolchain, String sdk})? request;
  @override
  Future<SwiftPmGateServices> loadSwiftPmGate() async {
    loads++;
    return SwiftPmGateServices(cacheRoot: '/fixture/cache', platformIdentity: 'windows-fixture', toolchainIdentity: () async => '{"toolchain":"fixture"}', sdkIdentity: () async => '{"sdk":"fixture"}', verify: ({required mode, required root, required platformIdentity, required toolchainIdentity, required sdkIdentity}) async {
      request = (mode: mode, root: root, platform: platformIdentity, toolchain: toolchainIdentity, sdk: sdkIdentity);
      return passed;
    });
  }
}
