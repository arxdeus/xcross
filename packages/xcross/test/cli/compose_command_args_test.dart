import 'package:args/command_runner.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:test/test.dart';
import 'package:xcross/src/cli/compose/compose_build_command.dart';
import 'package:xcross/src/cli/compose/compose_command.dart';
import 'package:xcross/src/cli/compose/compose_run_command.dart';
import 'package:xcross/src/cli/compose/compose_setup_command.dart';
import 'package:xcross/src/cli/runner.dart';
import 'package:xcross/src/compose/models/compose_build_options.dart';
import 'package:xcross/src/device/core_device_launch_profile.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/models/pack_result.dart';

import 'runtime_fixture.dart';

void main() {
  group('ComposeCommand', () {
    test('is registered by the top-level runner', () {
      expect(
        XcrossCli.buildRunner(
          testApplication(),
          configTerminal: TestTerminal(),
        ).commands.keys,
        contains('compose'),
      );
    });

    test('top-level description covers Flutter and Compose Multiplatform', () {
      final runner = XcrossCli.buildRunner(
        testApplication(),
        configTerminal: TestTerminal(),
      );

      expect(runner.description, contains('Flutter'));
      expect(runner.description, contains('Compose Multiplatform'));
      expect(runner.usage, contains('compose'));
      expect(runner.usage, contains('flutter'));
    });

    test('groups build, run, and setup', () {
      final application = testApplication();
      expect(
        ComposeCommand(
          application.runtime,
          application.pymd,
          application.sockets,
        ).subcommands.keys,
        containsAll(['build', 'run', 'setup']),
      );
    });
  });

  group('ComposeBuildCommand', () {
    late Command<void> command;

    setUp(() => command = ComposeBuildCommand(testRuntime()));

    test('defaults to debug configuration and ipa off', () {
      final results = command.argParser.parse([]);
      expect(results.option('configuration'), 'debug');
      expect(results.flag('ipa'), isFalse);
      expect(results.option('target-platform'), 'iphone');
    });

    test('accepts configuration, bundle id, app name, and ipa', () {
      final results = command.argParser.parse([
        '--configuration',
        'release',
        '--bundle-id',
        'dev.example.app',
        '--app-name',
        'Demo',
        '--ipa',
      ]);
      expect(results.option('configuration'), 'release');
      expect(results.option('bundle-id'), 'dev.example.app');
      expect(results.option('app-name'), 'Demo');
      expect(results.flag('ipa'), isTrue);
    });

    test(
      'passes simulator target and rejects simulator IPA before packing',
      () async {
        final seen = <ComposeBuildOptions>[];
        final targets = <String>[];
        final command = ComposeBuildCommand.withSeams(
          log: testLog(),
          packOperation:
              ({
                required options,
                required requireRunnableApp,
                required targetPlatform,
              }) async {
                seen.add(options);
                targets.add(targetPlatform);
                return const PackResult(
                  outputPath: 'build/xcross-ios-simulator/Demo.app',
                  bundleId: 'dev.example.demo',
                );
              },
          packageIpa: (_) async => throw StateError('unexpected IPA'),
          logDone: (_) {},
        );
        final runner = CommandRunner<void>('xcross', 'test')
          ..addCommand(command);
        await runner.run(['build', '--target-platform', 'simulator']);
        expect(targets, ['simulator']);
        expect(seen, hasLength(1));
        final reject = CommandRunner<void>('xcross', 'test')
          ..addCommand(ComposeBuildCommand(testRuntime()));
        await expectLater(
          reject.run(['build', '--target-platform', 'simulator', '--ipa']),
          throwsA(isA<XcrossError>()),
        );
      },
    );

    test('packages ipa only for app output and logs the ipa path', () async {
      final writes = <String>[];
      final seenOptions = <ComposeBuildOptions>[];
      final command = ComposeBuildCommand.withSeams(
        log: testLog(),
        packOperation:
            ({
              required options,
              required requireRunnableApp,
              required targetPlatform,
            }) async {
              seenOptions.add(options);
              return const PackResult(
                outputPath: 'build/Demo.app',
                bundleId: 'dev.example.demo',
              );
            },
        packageIpa: (appPath) async {
          writes.add('ipa:$appPath');
          return 'build/Demo.ipa';
        },
        logDone: writes.add,
      );
      final runner = CommandRunner<void>('xcross', 'test')..addCommand(command);

      await runner.run(['build', '--ipa']);

      expect(seenOptions.single.configuration, ComposeConfiguration.debug);
      expect(seenOptions.single.ipa, isTrue);
      expect(writes, ['ipa:build/Demo.app', 'Wrote build/Demo.ipa']);
    });

    test('does not package ipa for framework output', () async {
      final writes = <String>[];
      final command = ComposeBuildCommand.withSeams(
        log: testLog(),
        packOperation:
            ({
              required options,
              required requireRunnableApp,
              required targetPlatform,
            }) async => const PackResult(
              outputPath: 'build/Shared.framework',
              bundleId: 'dev.example.demo',
              kind: PackOutputKind.framework,
            ),
        packageIpa: (appPath) async {
          writes.add('unexpected-ipa:$appPath');
          return 'build/Demo.ipa';
        },
        logDone: writes.add,
      );
      final runner = CommandRunner<void>('xcross', 'test')..addCommand(command);

      await runner.run(['build', '--ipa']);

      expect(writes, ['Wrote build/Shared.framework']);
    });
  });

  group('ComposeRunCommand', () {
    late Command<void> command;

    setUp(() {
      final application = testApplication();
      command = ComposeRunCommand(
        application.runtime,
        application.pymd,
        sockets: application.sockets,
      );
    });

    test('supports Flutter-compatible device connection options', () {
      final results = command.argParser.parse([
        '-d',
        'iPhone',
        '-u',
        'UDID',
        '--usb',
        '--wifi',
        '--device-connection',
        'wireless',
      ]);
      expect(results.option('device-id'), 'iPhone');
      expect(results.option('udid'), 'UDID');
      expect(results.flag('usb'), isTrue);
      expect(results.flag('wifi'), isTrue);
      expect(results.option('device-connection'), 'wireless');
    });

    test('-a app arguments are repeatable and verbose is accepted', () {
      final results = command.argParser.parse([
        '-a',
        'one',
        '--app-argument',
        'two',
        '-v',
      ]);
      expect(results.multiOption('app-argument'), ['one', 'two']);
      expect(results.flag('verbose'), isTrue);
    });

    test(
      'builds a runnable app and launches through native CoreDevice profile',
      () async {
        PackResult? launchedPack;
        final launchedSelectors = <String?>[];
        final launchedModes = <DeviceSearchMode>[];
        final launchedProfiles = <CoreDeviceLaunchProfile>[];
        final seenRequireRunnable = <bool>[];
        final command = ComposeRunCommand.withSeams(
          projectRoot: '/test/project',
          log: testLog(),
          files: testRuntime().host.fileSystem,
          packOperation:
              ({
                required options,
                required requireRunnableApp,
                required targetPlatform,
              }) async {
                seenRequireRunnable.add(requireRunnableApp);
                return const PackResult(
                  outputPath: 'build/Demo.app',
                  bundleId: 'dev.example.demo',
                );
              },
          runDevice:
              ({
                required pack,
                required selector,
                required mode,
                required launchProfile,
                onRestartRequested,
              }) async {
                launchedPack = pack;
                launchedSelectors.add(selector);
                launchedModes.add(mode);
                launchedProfiles.add(launchProfile);
              },
        );
        final runner = CommandRunner<void>('xcross', 'test')
          ..addCommand(command);

        await runner.run([
          'run',
          '-u',
          'UDID',
          '--device-connection',
          'attached',
          '-a',
          'one',
          '-a',
          'two',
        ]);

        expect(seenRequireRunnable, [true]);
        expect(launchedPack?.outputPath, 'build/Demo.app');
        expect(launchedSelectors, ['UDID']);
        expect(launchedModes, [DeviceSearchMode.usb]);
        expect(launchedProfiles.single.arguments, ['one', 'two']);
        expect(
          launchedProfiles.single.argumentsForLaunch(
            isDap: true,
            vmServiceBindAddress: '0.0.0.0',
          ),
          ['one', 'two'],
        );
      },
    );
  });

  group('ComposeRunCommand --bundle-id', () {
    test('passes the bundle id through to the build', () async {
      final seen = <String?>[];
      Future<void> run(List<String> args) {
        final command = ComposeRunCommand.withSeams(
          projectRoot: '/test/project',
          log: testLog(),
          files: testRuntime().host.fileSystem,
          packOperation:
              ({
                required options,
                required requireRunnableApp,
                required targetPlatform,
              }) async {
                seen.add(options.bundleId);
                return const PackResult(
                  outputPath: 'build/Demo.app',
                  bundleId: 'sg.example.app',
                );
              },
          runDevice:
              ({
                required pack,
                required selector,
                required mode,
                required launchProfile,
                onRestartRequested,
              }) async {},
        );
        return (CommandRunner<void>(
          'xcross',
          'test',
        )..addCommand(command)).run(args);
      }

      await run(['run', '--bundle-id', 'sg.example.app']);
      await run(['run']);

      expect(seen, ['sg.example.app', null]);
    });
  });

  group('ComposeSetupCommand', () {
    late Command<void> command;

    setUp(() => command = ComposeSetupCommand(testRuntime()));

    test('accepts check and force flags', () {
      final results = command.argParser.parse(['--check', '--force']);
      expect(results.flag('check'), isTrue);
      expect(results.flag('force'), isTrue);
    });

    test(
      '--check reports every resolver problem without ensuring toolchains',
      () async {
        final command = ComposeSetupCommand.withSeams(
          log: testLog(),
          problems: () async => const ['missing java', 'missing swiftc'],
          ensure: ({required force}) {
            throw StateError('ensure must not run during --check');
          },
          logDone: (_) {},
        );
        final runner = CommandRunner<void>('xcross', 'test')
          ..addCommand(command);

        await expectLater(
          runner.run(['setup', '--check']),
          throwsA(
            isA<XcrossError>()
                .having(
                  (error) => error.message,
                  'message',
                  contains('missing java'),
                )
                .having(
                  (error) => error.message,
                  'message',
                  contains('missing swiftc'),
                ),
          ),
        );
      },
    );
  });
}
