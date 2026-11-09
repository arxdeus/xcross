import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:darwin_sdk_kit/target/iphone/iphone_target.dart';
import 'package:darwin_sdk_kit/target/simulator/simulator_target.dart';
import 'package:test/test.dart';
import 'package:xcross/src/target/iphone/flutter/iphone_flutter_target.dart';
import 'package:xcross/src/target/iphone/swiftpm/iphone_swiftpm_target.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';
import 'package:xcross/src/target/shared/swiftpm/swiftpm_target_policy.dart';
import 'package:xcross/src/target/simulator/flutter/simulator_flutter_target.dart';
import 'package:xcross/src/target/simulator/swiftpm/simulator_swiftpm_target.dart';

void main() {
  final host = LinuxHost(architecture: 'x64');

  // workspaceSuffix is part of the SwiftPM cache key
  // (`swiftpm/<hash><suffix>`): these values must never change.
  void expectPolicy(
    SwiftPmTargetPolicy<LinuxHost> swiftPm,
    FlutterTargetBuildPolicy<LinuxHost> flutter, {
    required String suffix,
    required String artifacts,
    required List<String> slices,
    required String? variant,
  }) {
    for (final policy in <SwiftPmTargetPolicy<LinuxHost>>[swiftPm, flutter]) {
      expect(policy.workspaceSuffix, suffix);
      expect(policy.binaryArtifactDirectory, artifacts);
      expect(policy.xcframeworkSliceIdentifiers, slices);
      expect(policy.matchesLibraryVariant(variant), isTrue);
      expect(policy.matchesLibraryVariant('other'), isFalse);
    }
  }

  test('Flutter and SwiftPM iPhone policies share one SwiftPM layout', () {
    final target = IPhoneTarget(host);
    final flutter = IPhoneFlutterTarget(target);
    expectPolicy(
      IPhoneSwiftPmTarget(target),
      flutter,
      suffix: '',
      artifacts: 'binary-artifacts-v1',
      slices: const ['ios-arm64'],
      variant: null,
    );
    expect(flutter.engineSliceIdentifiers, flutter.xcframeworkSliceIdentifiers);
  });

  test('Flutter and SwiftPM simulator policies share one SwiftPM layout', () {
    final target = SimulatorTarget(host);
    final flutter = SimulatorFlutterTarget(target);
    expectPolicy(
      SimulatorSwiftPmTarget(target),
      flutter,
      suffix: '-simulator',
      artifacts: 'binary-artifacts-simulator-v1',
      slices: const ['ios-arm64_x86_64-simulator', 'ios-arm64-simulator'],
      variant: 'simulator',
    );
    expect(flutter.engineSliceIdentifiers, flutter.xcframeworkSliceIdentifiers);
  });
}
