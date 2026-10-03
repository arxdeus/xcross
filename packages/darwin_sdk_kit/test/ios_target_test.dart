import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late MacOSHost host;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('xcross-sdk-fixture-');
    host = MacOSHost(temporaryDirectory: tmp.path);
  });
  tearDown(() => tmp.delete(recursive: true));

  group('IosBuildPlatform', () {
    test('preserves ARM64 device values', () {
      const target = IPhoneBuildPlatform();
      expect(target.sdkName, 'iphoneos');
      expect(target.platformName, 'iPhoneOS');
      expect(target.swiftSdkTriple, 'arm64-apple-ios');
      expect(target.linkerPlatform, 'ios');
      expect(target.buildTriple('15.0'), 'arm64-apple-ios15.0');
    });

    test('selects ARM64 simulator values', () {
      const target = SimulatorBuildPlatform();
      expect(target.sdkName, 'iphonesimulator');
      expect(target.platformName, 'iPhoneSimulator');
      expect(target.swiftSdkTriple, 'arm64-apple-ios-simulator');
      expect(target.linkerPlatform, 'ios-simulator');
      expect(target.buildTriple('15.0'), 'arm64-apple-ios15.0-simulator');
      expect(target.buildTriple('26.1'), 'arm64-apple-ios26.1-simulator');
    });
  });

  group('typed targets', () {
    test('keeps the original coherent host', () {
      final phone = IPhoneTarget(host);
      final simulator = SimulatorTarget(host);
      expect(phone.host, same(host));
      expect(simulator.host, same(host));
      expect(
        phone.buildPlatform.minimumVersionFlag('15.0'),
        '-miphoneos-version-min=15.0',
      );
      expect(
        simulator.buildPlatform.minimumVersionFlag('15.0'),
        '-mios-simulator-version-min=15.0',
      );
    });
  });
}
