@TestOn('mac-os || linux')
@Tags(['live'])
library;

import 'dart:async';
import 'dart:io';

import 'package:cli_kit/composition/native_host.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:open_apple_macros/host/shared/posix_toolchain_plugin_layout.dart';
import 'package:open_apple_macros/shared/open_apple_macros_server.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fixture_swift_toolchain.dart';

const _probeManifest = '''
// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "Probe",
  platforms: [.iOS(.v15)],
  targets: [.target(name: "Probe")]
)
''';

const _probeSource = r'''
import SwiftUI
import UIKit

public enum Context {
  @TaskLocal public static var value: Int = 0
}

extension EnvironmentValues {
  @Entry var probeValue: Int = 2
}

public struct ProbeView: View {
  @State private var count = 0
  public var body: some View { Text("\(count)") }
}

#Preview {
  ProbeView()
}

@available(iOS 17.0, *)
#Preview("Kit") {
  UIView()
}
''';

void main() {
  final environment = Platform.environment;
  final swiftSdks = environment['OPEN_APPLE_MACROS_SWIFT_SDKS'];
  final swiftSdk =
      environment['OPEN_APPLE_MACROS_SWIFT_SDK'] ?? 'arm64-apple-ios-simulator';
  final cacheRoot =
      environment['OPEN_APPLE_MACROS_CACHE'] ??
      p.join(Directory.systemTemp.path, 'open-apple-macros-live');

  test(
    'builds the server and expands Apple macros for an iOS probe',
    () async {
      final host = detectPlatformHost();
      final runner = ProcessRunner(
        host,
        log: Log(output: FixtureLogOutput()),
        stdinStream: const Stream<List<int>>.empty(),
        stdoutSink: IOSink(StreamController<List<int>>.broadcast().sink),
        stderrSink: IOSink(StreamController<List<int>>.broadcast().sink),
      );
      final build =
          await OpenAppleMacrosServer(
            runner: runner,
            layout: const PosixToolchainPluginLayout(),
          ).ensure(
            cacheRoot: cacheRoot,
            swiftDriver: const SwiftToolCommand('swiftc'),
            swiftBuild: const SwiftToolCommand('swift', ['build']),
          );
      expect(File(build.executable).existsSync(), isTrue);
      expect(Directory(build.toolchainPluginDirectory).existsSync(), isTrue);

      final probe = Directory.systemTemp.createTempSync('open-apple-probe-');
      addTearDown(() => probe.deleteSync(recursive: true));
      File(
        p.join(probe.path, 'Package.swift'),
      ).writeAsStringSync(_probeManifest);
      File(p.join(probe.path, 'Sources', 'Probe', 'Probe.swift'))
        ..createSync(recursive: true)
        ..writeAsStringSync(_probeSource);
      final result = await Process.run('swift', [
        'build',
        '--build-system',
        'native',
        '--package-path',
        probe.path,
        '--swift-sdks-path',
        swiftSdks!,
        '--swift-sdk',
        swiftSdk,
        ...build.swiftBuildArguments,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    skip: swiftSdks == null
        ? 'Set OPEN_APPLE_MACROS_SWIFT_SDKS to an installed Swift SDK directory'
        : false,
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
