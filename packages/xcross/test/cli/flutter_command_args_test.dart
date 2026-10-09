// Contract tests for the flutter run/build CLI argument parsers: flag names,
// abbreviations, defaults, and allowed-values that would silently break if
// someone typo'd a flag or changed a default. Only exercises the public
// `Command.argParser` seam from package:args — no private state.
import 'package:args/command_runner.dart';
import 'package:test/test.dart';
import 'package:xcross/src/composition/cli/flutter_build_command.dart';
import 'package:xcross/src/composition/cli/flutter_run_command.dart';
import 'package:xcross/src/composition/cli/runner.dart';
import 'package:xcross/src/shared/cli/basic/auth_command.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_mode.dart';
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_options.dart';
import 'package:xcross/src/shared/models/pack_result.dart';
import 'package:xcross/src/target/iphone/device/core_device_launch_profile.dart';

import '../log_fixture.dart';
import 'runtime_fixture.dart';

void main() {
  group('FlutterRunCommand.shouldUseCoreDevice', () {
    test('uses CoreDevice for confirmed iOS 17+ and unknown devices', () {
      expect(FlutterRunCommand.shouldUseCoreDevice(17), isTrue);
      expect(FlutterRunCommand.shouldUseCoreDevice(null), isTrue);
    });

    test('rejects confirmed older devices', () {
      expect(FlutterRunCommand.shouldUseCoreDevice(16), isFalse);
    });
  });

  group('FlutterRunCommand', () {
    late Command<void> command;

    setUp(() {
      final application = testApplication();
      command = FlutterRunCommand(
        application.runtime,
        application.pymd,
        sockets: application.sockets,
      );
    });

    test(
      'defaults: usb/wifi off, device-connection both, target/pub inherited',
      () {
        final results = command.argParser.parse([]);
        expect(results.flag('usb'), isFalse);
        expect(results.flag('wifi'), isFalse);
        expect(results.option('device-connection'), 'both');
        expect(results.option('target'), 'lib/main.dart');
        expect(results.flag('pub'), isTrue);
      },
    );

    test('--usb sets the usb flag', () {
      final results = command.argParser.parse(['--usb']);
      expect(results.flag('usb'), isTrue);
    });

    test('--wifi sets the wifi flag', () {
      final results = command.argParser.parse(['--wifi']);
      expect(results.flag('wifi'), isTrue);
    });

    test('-d sets device-id', () {
      final results = command.argParser.parse(['-d', 'iPhone']);
      expect(results.option('device-id'), 'iPhone');
    });

    test('-u sets udid', () {
      final results = command.argParser.parse(['-u', 'ABCD1234']);
      expect(results.option('udid'), 'ABCD1234');
    });

    test('--device-connection accepts an allowed value', () {
      final results = command.argParser.parse([
        '--device-connection',
        'attached',
      ]);
      expect(results.option('device-connection'), 'attached');
    });

    // Regression check: --device-connection is declared with a fixed
    // `allowed` set (attached/wireless/both); a typo'd or removed value must
    // be rejected at parse time rather than silently reaching
    // DeviceConnection.values.byName and picking an unintended search mode.
    test('--device-connection rejects a value outside the allowed set', () {
      expect(
        () => command.argParser.parse(['--device-connection', 'bogus']),
        throwsFormatException,
      );
    });

    test('--route sets the initial route', () {
      final results = command.argParser.parse(['--route', '/home']);
      expect(results.option('route'), '/home');
    });

    test('-a is repeatable for dart-entrypoint-args', () {
      final results = command.argParser.parse(['-a', 'foo', '-a', 'bar']);
      expect(results.multiOption('dart-entrypoint-args'), ['foo', 'bar']);
    });

    test('-v sets verbose', () {
      final results = command.argParser.parse(['-v']);
      expect(results.flag('verbose'), isTrue);
    });
  });

  group('FlutterRunCommand precompiled launch', () {
    late List<FlutterBuildOptions> packed;
    late List<CoreDeviceLaunchProfile> launched;

    Future<void> run(
      List<String> args, {
      Map<String, String> environment = const {},
    }) {
      final application = testApplication(environment: environment);
      final runner = CommandRunner<void>('xcross', 'test')
        ..addCommand(
          FlutterRunCommand.withSeams(
            application.runtime,
            application.pymd,
            sockets: application.sockets,
            pack: (options) async {
              packed.add(options);
              return const PackResult(
                outputPath: 'build/Runner.app',
                bundleId: 'dev.example.app',
              );
            },
            runDevice:
                ({
                  required pack,
                  required selector,
                  required mode,
                  required launchProfile,
                }) async => launched.add(launchProfile),
          ),
        );
      return runner.run(['run', ...args]);
    }

    setUp(() {
      packed = [];
      launched = [];
    });

    test('profile builds AOT and launches with the VM Service', () async {
      await run(['--profile', '--route=/home']);

      expect(packed.single.buildMode, FlutterBuildMode.profile);
      final profile = launched.single;
      expect(profile.buildMode, FlutterBuildMode.profile);
      expect(profile.hotReload, isNull);
      expect(profile.debuggingEnabled, isTrue);
      expect(
        profile.argumentsForLaunch(
          isDap: false,
          vmServiceBindAddress: '0.0.0.0',
        ),
        containsAll([
          '--vm-service-host=0.0.0.0',
          '--enable-dart-profiling',
          '--route=/home',
        ]),
      );
    });

    test('release builds AOT and launches without debugging', () async {
      await run(['--release']);

      expect(packed.single.buildMode, FlutterBuildMode.release);
      final profile = launched.single;
      expect(profile.buildMode, FlutterBuildMode.release);
      expect(profile.hotReload, isNull);
      expect(profile.debuggingEnabled, isFalse);
      expect(
        profile.argumentsForLaunch(isDap: false, vmServiceBindAddress: '::0'),
        isEmpty,
      );
    });

    for (final mode in ['--profile', '--release']) {
      test('DAP rejects a $mode launch', () async {
        await expectLater(
          run([mode], environment: const {'XCROSS_DAP': '1'}),
          throwsA(
            isA<XcrossError>().having(
              (e) => e.message,
              'message',
              'DAP launch requires a debug build.',
            ),
          ),
        );
        expect(launched, isEmpty);
      });
    }
  });

  group('FlutterBuildCommand', () {
    test('accepts explicit simulator debug and preserves device default', () {
      final command = FlutterBuildCommand(testRuntime());
      expect(command.argParser.parse([]).option('target-platform'), 'iphone');
      final results = command.argParser.parse([
        '--target-platform',
        'simulator',
        '--debug',
      ]);
      expect(results.option('target-platform'), 'simulator');
      expect(results.flag('debug'), isTrue);
    });

    for (final flags in [
      ['--target-platform', 'simulator', '--ipa'],
      ['--target-platform', 'simulator', '--profile'],
      ['--target-platform', 'simulator', '--release'],
      ['--debug', '--profile'],
    ]) {
      test(
        'rejects unsupported combination $flags before accessing a project',
        () async {
          final runner = CommandRunner<void>('test', 'test')
            ..addCommand(FlutterBuildCommand(testRuntime()));
          await expectLater(
            runner.run(['build', ...flags]),
            throwsA(
              flags.contains('--ipa')
                  ? isA<XcrossError>()
                  : isA<UsageException>(),
            ),
          );
        },
      );
    }

    late Command<void> command;

    setUp(() => command = FlutterBuildCommand(testRuntime()));

    test('defaults: target/pub inherited, ipa off', () {
      final results = command.argParser.parse([]);
      expect(results.option('target'), 'lib/main.dart');
      expect(results.flag('pub'), isTrue);
      expect(results.flag('ipa'), isFalse);
    });

    // Regression check: `pub` is declared with defaultsTo: true and no
    // negatable: false, so --no-pub must keep working to let a debug/CI
    // build skip `flutter pub get`.
    test('--no-pub disables pub', () {
      final results = command.argParser.parse(['--no-pub']);
      expect(results.flag('pub'), isFalse);
    });

    test('-D is repeatable for dart-define', () {
      final results = command.argParser.parse(['-D', 'A=1', '-D', 'B=2']);
      expect(results.multiOption('dart-define'), ['A=1', 'B=2']);
    });

    test('--dart-define-from-file collects file paths', () {
      final results = command.argParser.parse([
        '--dart-define-from-file',
        'defines.json',
      ]);
      expect(results.multiOption('dart-define-from-file'), ['defines.json']);
    });

    test('--build-name and --build-number set version fields', () {
      final results = command.argParser.parse([
        '--build-name',
        '2.1.0',
        '--build-number',
        '7',
      ]);
      expect(results.option('build-name'), '2.1.0');
      expect(results.option('build-number'), '7');
    });

    test('-i sets the ipa flag', () {
      final results = command.argParser.parse(['-i']);
      expect(results.flag('ipa'), isTrue);
    });

    test('-t and --flavor override target and set flavor', () {
      final results = command.argParser.parse([
        '-t',
        'lib/other.dart',
        '--flavor',
        'dev',
      ]);
      expect(results.option('target'), 'lib/other.dart');
      expect(results.option('flavor'), 'dev');
    });
  });

  group('AuthCommand', () {
    late Command<void> command;

    setUp(
      () => command = AuthCommand(
        commandPrompt: TestCommandPrompt(),
        createAdiHttpClient: testRuntime().createHttpClient,
        log: testLog(),
        hostServices: testRuntime().appleHostServices,
        createNativeLibraryLoader: testRuntime().createNativeLibraryLoader,
        createHttpClient: testRuntime().createAppleHttpClient,
      ),
    );

    test('exposes all six option names', () {
      final options = command.argParser.options;
      expect(
        options.keys,
        containsAll([
          'issuer-id',
          'key-id',
          'private-key',
          'apple-id',
          'password',
          'adi-library-dir',
        ]),
      );
    });

    test('apple-id wasParsed is false by default and true when set', () {
      expect(command.argParser.parse([]).wasParsed('apple-id'), isFalse);
      expect(
        command.argParser.parse(['--apple-id', 'a@b.c']).wasParsed('apple-id'),
        isTrue,
      );
    });
  });

  group('XcrossCli global -v', () {
    test('-v sets the verbose flag on the runner', () {
      final results = XcrossCli.buildRunner(
        testApplication(),
        configTerminal: TestTerminal(),
      ).argParser.parse(['-v']);
      expect(results.flag('verbose'), isTrue);
    });

    test('verbose is accepted after the flutter build command', () {
      final results = XcrossCli.buildRunner(
        testApplication(),
        configTerminal: TestTerminal(),
      ).argParser.parse(['flutter', 'build', '--verbose']);
      expect(results.flag('verbose'), isTrue);
      expect(results.command!.name, 'flutter');
      expect(results.command!.command!.name, 'build');
    });
  });
}
