// Contract tests for the flutter run/build CLI argument parsers: flag names,
// abbreviations, defaults, and allowed-values that would silently break if
// someone typo'd a flag or changed a default. Only exercises the public
// `Command.argParser` seam from package:args — no private state.
import 'package:args/command_runner.dart';
import 'package:test/test.dart';
import 'package:xcross/src/cli/flutter/flutter_build_args.dart';
import 'package:xcross/src/cli/flutter/flutter_run_args.dart';

void main() {
  group('shouldUseCoreDevice', () {
    test(
      'uses CoreDevice for confirmed iOS 17+ and unknown native devices',
      () {
        expect(shouldUseCoreDevice(osMajor: 17, nativeBackend: false), isTrue);
        expect(shouldUseCoreDevice(osMajor: null, nativeBackend: true), isTrue);
      },
    );

    test(
      'keeps confirmed older and unknown xtool devices on legacy launch',
      () {
        expect(shouldUseCoreDevice(osMajor: 16, nativeBackend: true), isFalse);
        expect(
          shouldUseCoreDevice(osMajor: null, nativeBackend: false),
          isFalse,
        );
      },
    );
  });

  group('FlutterRunCommand', () {
    late Command<void> command;

    setUp(() => command = FlutterRunCommand());

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

  group('FlutterBuildCommand', () {
    late Command<void> command;

    setUp(() => command = FlutterBuildCommand());

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
}
