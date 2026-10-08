import 'dart:io';

import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/host/macos/macos_host.dart';
import 'package:cli_kit/host/windows/windows_host.dart';
import 'package:darwin_sdk_kit/target/iphone/iphone_target.dart';
import 'package:darwin_sdk_kit/target/simulator/simulator_target.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/host/linux/compose/linux_compose_host.dart';
import 'package:xcross/src/host/macos/compose/macos_compose_host.dart';
import 'package:xcross/src/host/windows/compose/windows_compose_host.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/target/iphone/compose/iphone_compose_target.dart';
import 'package:xcross/src/target/simulator/compose/simulator_compose_target.dart';

import 'support/compose_platforms.dart';

void main() {
  late ComposeTestSession session;
  setUp(() {
    session = createComposeTestSession();
  });
  tearDown(() => session.dispose());
  test(
    'explicit fixture sessions isolate effects and dispose owned resources',
    () async {
      final first = createComposeTestSession();
      final second = createComposeTestSession();
      try {
        expect(identical(first.fixtureRunner, second.fixtureRunner), isFalse);
        expect(identical(first.fixtureTools, second.fixtureTools), isFalse);
        expect(identical(first.fixtureLog, second.fixtureLog), isFalse);
        expect(
          identical(first.fixtureDownloader, second.fixtureDownloader),
          isFalse,
        );
        expect(identical(first.hosts.linuxX64, second.hosts.linuxX64), isFalse);
        expect(first.temporaryRoot.path, isNot(second.temporaryRoot.path));
        first.stdoutSink.write('first');
        await first.stdoutSink.flush();
        expect(first.stdoutConsumer.bytes, [102, 105, 114, 115, 116]);
        expect(second.stdoutConsumer.bytes, isEmpty);
      } finally {
        await Future.wait([first.dispose(), second.dispose()]);
      }
      expect(first.temporaryRoot.existsSync(), isFalse);
      expect(second.temporaryRoot.existsSync(), isFalse);
    },
  );

  test('named host strategies select exact archives and overlay plans', () {
    expect(session.hosts.linuxX64.installationArtifacts('2.2.20'), [
      'kotlin-native-prebuilt-2.2.20-linux-x86_64.tar.gz',
      'kotlin-native-prebuilt-2.2.20-macos-x86_64.tar.gz',
    ]);
    expect(
      session.hosts.windowsX64.hostArtifact('2.2.20'),
      'kotlin-native-prebuilt-2.2.20-windows-x86_64.zip',
    );
    expect(session.hosts.macosArm64.installationArtifacts('2.2.20'), [
      'kotlin-native-prebuilt-2.2.20-macos-aarch64.tar.gz',
    ]);
    expect(session.hosts.macosX64.installationArtifacts('2.2.20'), [
      'kotlin-native-prebuilt-2.2.20-macos-x86_64.tar.gz',
    ]);
  });

  for (final architecture in ['arm64', 'aarch64', ' ARM64 ']) {
    test('native macOS $architecture validates matching JVM architecture', () {
      final host = MacOSComposeHost(MacOSHost(architecture: architecture));
      expect(host.classifier, 'macos-aarch64');
      expect(host.konanTarget, 'macos_arm64');
      expect(host.supportsJavaArchitecture('aarch64'), isTrue);
      expect(host.supportsJavaArchitecture('amd64'), isFalse);
    });
    test(
      'rejects unsupported Linux and Windows compiler host $architecture',
      () {
        expect(
          () => LinuxComposeHost(LinuxHost(architecture: architecture)),
          throwsA(
            isA<XcrossError>().having(
              (error) => error.message,
              'reason',
              contains('linuxArm64 is a compilation target'),
            ),
          ),
        );
        expect(
          () => WindowsComposeHost(
            WindowsHost(architecture: architecture),
            runningExecutable: '/unused-xcross',
          ),
          throwsA(isA<XcrossError>()),
        );
      },
    );
  }

  test(
    'unknown architecture is never assumed to be a supported compiler host',
    () {
      expect(() => MacOSComposeHost(MacOSHost()), throwsA(isA<XcrossError>()));
      expect(() => LinuxComposeHost(LinuxHost()), throwsA(isA<XcrossError>()));
      expect(
        () => WindowsComposeHost(
          WindowsHost(),
          runningExecutable: '/unused-xcross',
        ),
        throwsA(isA<XcrossError>()),
      );
    },
  );

  test('execution and filesystem policies own naming and response files', () {
    final posix = session.hosts.linuxX64;
    final windows = session.hosts.windowsX64;
    expect(posix.konancExecutable('/kn'), p.join('/kn', 'bin', 'konanc'));
    expect(windows.konancExecutable('/kn'), p.join('/kn', 'bin', 'konanc.bat'));
    expect(
      posix.compilerArguments(
        ['launcher'],
        ['-target', 'ios_arm64'],
        () => fail('POSIX must not emit a response file'),
      ),
      ['launcher', '-target', 'ios_arm64'],
    );
    expect(
      windows.compilerArguments(
        ['launcher'],
        ['-target', 'ios_arm64'],
        () => 'args.txt',
      ),
      ['launcher', '@args.txt'],
    );
    expect(posix.canCacheLibraryNames(['unsafe:name']), isTrue);
    expect(windows.canCacheLibraryNames(['unsafe:name']), isFalse);
    expect(windows.canCacheLibraryNames(['safe_name']), isTrue);
    expect(windows.shimFingerprintFiles('/xcross').single.path, '/xcross');
    expect(posix.shimFingerprintFiles('/xcross'), isEmpty);
  });

  test('host-bound target carries one consistent platform descriptor', () {
    final host = session.hosts.macosArm64;
    final iphone = IPhoneComposeTarget(IPhoneTarget(host.host), host);
    final simulator = SimulatorComposeTarget(
      SimulatorTarget(host.host),
      host,
      signing: FixtureSimulatorSigning(host.host),
    );
    expect(iphone.host, same(host.host));
    expect(simulator.host, same(host.host));
    expect(iphone.targetTriple, 'arm64-apple-ios15.0');
    expect(simulator.targetTriple, 'arm64-apple-ios15.0-simulator');
    expect(iphone.gradleTarget, 'iosArm64');
    expect(simulator.gradleTarget, 'iosSimulatorArm64');
    expect(simulator.compilerRtName, 'libclang_rt.iossim.a');
    expect(simulator.gradleArguments('/kn'), ['-Pkotlin.native.home=/kn']);
    expect(iphone.gradleArguments('/kn'), isEmpty);
    expect(
      () => simulator.validateOutput(ipa: true),
      throwsA(isA<XcrossError>()),
    );
  });

  test('simulator signer must belong to exact same host instance', () {
    final host = session.hosts.macosArm64;
    expect(
      () => SimulatorComposeTarget(
        SimulatorTarget(host.host),
        host,
        signing: FixtureSimulatorSigning(MacOSHost(architecture: 'arm64')),
      ),
      throwsArgumentError,
    );
  });

  test(
    'POSIX shim behavior handles absent dsymutil without command failure',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'xcross-compose-shim-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = p.join(directory.path, 'dsymutil');
      final executable = <String>[];
      await session.hosts.linuxX64.writeShim(
        path,
        'dsymutil',
        'XCROSS_APPLE_TOOL_DSYMUTIL',
        '/unused',
        executable.add,
      );
      expect(File(path).readAsStringSync(), contains('then exit 0'));
      expect(executable, [path]);
    },
  );
}
