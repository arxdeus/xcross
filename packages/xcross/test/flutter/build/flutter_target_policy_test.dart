import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/target/iphone/flutter/iphone_flutter_target.dart';
import 'package:xcross/src/target/simulator/flutter/simulator_flutter_target.dart';

void main() {
  late Directory root;
  late LinuxHost host;
  late IPhoneFlutterTarget<LinuxHost> iphone;
  late SimulatorFlutterTarget<LinuxHost> simulator;

  setUp(() {
    root = Directory.systemTemp.createTempSync('xcross_target_policy_');
    host = LinuxHost(
      architecture: 'arm64',
      currentDirectory: root.path,
      temporaryDirectory: root.path,
    );
    iphone = IPhoneFlutterTarget(IPhoneTarget(host));
    simulator = SimulatorFlutterTarget(SimulatorTarget(host));
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('isolates bundle, intermediate, artifact and sanitizer policies', () {
    expect(
      iphone.outputDirectory(root.path),
      p.join(root.path, 'build', 'xcross-ios'),
    );
    expect(
      simulator.outputDirectory(root.path),
      p.join(root.path, 'build', 'xcross-ios-simulator'),
    );
    expect(
      iphone.buildDirectory(root.path, 'kernel'),
      p.join(root.path, 'build', 'kernel'),
    );
    expect(
      simulator.buildDirectory(root.path, 'kernel'),
      p.join(root.path, 'build', 'xcross-ios-simulator', 'kernel'),
    );
    expect(
      iphone.binaryArtifactDirectory,
      isNot(simulator.binaryArtifactDirectory),
    );
    expect(iphone.workspaceSuffix, '');
    expect(simulator.workspaceSuffix, '-simulator');
    expect(iphone.sanitizerRuntimeLibrary, 'libclang_rt.ios.a');
    expect(simulator.sanitizerRuntimeLibrary, 'libclang_rt.iossim.a');
    expect(iphone.matchesLibraryVariant(null), isTrue);
    expect(iphone.matchesLibraryVariant('simulator'), isFalse);
    expect(simulator.matchesLibraryVariant('simulator'), isTrue);
    expect(simulator.matchesLibraryVariant(null), isFalse);
  });

  test('never accepts opposite-target engine slice', () {
    final deviceSlice = p.join(root.path, 'ios-arm64');
    Directory(
      p.join(deviceSlice, 'Flutter.framework'),
    ).createSync(recursive: true);
    expect(iphone.selectEngineSlice(root.path), deviceSlice);
    expect(
      () => simulator.selectEngineSlice(root.path),
      throwsA(isA<FlutterBuildError>()),
    );
    Directory(deviceSlice).deleteSync(recursive: true);
    final simSlice = p.join(root.path, 'ios-arm64-simulator');
    Directory(
      p.join(simSlice, 'Flutter.framework'),
    ).createSync(recursive: true);
    expect(simulator.selectEngineSlice(root.path), simSlice);
    expect(
      () => iphone.selectEngineSlice(root.path),
      throwsA(isA<FlutterBuildError>()),
    );
  });

  test('simulator prefers combined slice with arm64 fallback', () {
    final fallback = p.join(root.path, 'ios-arm64-simulator');
    final combined = p.join(root.path, 'ios-arm64_x86_64-simulator');
    Directory(
      p.join(fallback, 'Flutter.framework'),
    ).createSync(recursive: true);
    Directory(
      p.join(combined, 'Flutter.framework'),
    ).createSync(recursive: true);
    expect(simulator.selectEngineSlice(root.path), combined);
    Directory(combined).deleteSync(recursive: true);
    expect(simulator.selectEngineSlice(root.path), fallback);
  });

  test('target strategy owns plist platform metadata', () {
    const xml = '<plist><dict></dict></plist>';
    final deviceXml = iphone.transformPlist(xml);
    final simulatorXml = simulator.transformPlist(deviceXml);
    expect(deviceXml, contains('<string>iPhoneOS</string>'));
    expect(deviceXml, contains('<string>iphoneos</string>'));
    expect(simulatorXml, contains('<string>iPhoneSimulator</string>'));
    expect(simulatorXml, contains('<string>iphonesimulator</string>'));
    expect(simulatorXml, isNot(contains('<string>iPhoneOS</string>')));
    expect(simulatorXml, isNot(contains('<string>iphoneos</string>')));
    final restored = iphone.transformPlist(simulatorXml);
    expect(restored, contains('<string>iPhoneOS</string>'));
    expect(restored, isNot(contains('<string>iPhoneSimulator</string>')));
  });
}
