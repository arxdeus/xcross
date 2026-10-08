import 'dart:io';
import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/shared/process/process.dart';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/host/linux/sdk/linux_swift_toolchain_host.dart';
import 'package:xcross/src/host/macos/sdk/macos_swift_toolchain_host.dart';
import 'package:xcross/src/host/windows/sdk/windows_swift_toolchain_host.dart';
import 'package:xcross/src/shared/cli/basic/internal/swift_requirement.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/sdk/swift_toolchain_host.dart';
import '../host_operations_fixtures.dart';
import '../setup/host_ops_residual_fixtures.dart';

void main() {
  final host = LinuxHost();
  final runner = fixtureRunner(host, log: fixtureLog());
  group('SwiftRequirement.require', () {
    test('returns the located toolchain when Swift is on PATH', () async {
      expect(
        await _requireSwift(
          'install the Darwin SDK',
          runner: runner,
          installGuidance: const LinuxSwiftToolchainHost().installGuidance,
          locate: (name) async => '/opt/swift/bin/$name',
        ),
        '/opt/swift/bin/${runner.hostExecutableName('swift')}',
      );
    });

    test('names the action and how to verify the fix', () async {
      await expectLater(
        _requireSwift(
          'install the Darwin SDK',
          runner: runner,
          installGuidance: const LinuxSwiftToolchainHost().installGuidance,
          locate: (_) async => null,
        ),
        throwsA(
          isA<XcrossError>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('cannot install the Darwin SDK'),
              contains('swift.org/install/linux'),
              contains('swift --version'),
            ),
          ),
        ),
      );
    });

    test('points each host at its own installer', () async {
      Future<String> hintFor(SwiftToolchainHostInterface policy) async {
        try {
          await _requireSwift(
            'set up this host',
            runner: runner,
            installGuidance: policy.installGuidance,
            locate: (_) async => null,
          );
        } on XcrossError catch (error) {
          return error.message;
        }
        fail('expected a missing-Swift failure for $policy');
      }

      expect(
        await hintFor(const WindowsSwiftToolchainHost()),
        contains('install/windows'),
      );
      expect(
        await hintFor(const MacOSSwiftToolchainHost()),
        contains('install/macos'),
      );
      expect(
        await hintFor(const LinuxSwiftToolchainHost()),
        contains('install/linux'),
      );
    });
  });

  group('Swift toolchain failure guidance', () {
    for (final status in [0xC0000135, 0xC0000135 - 0x100000000]) {
      test('only Windows diagnoses DLL status $status', () {
        expect(
          const WindowsSwiftToolchainHost().failureGuidance(status),
          allOf(
            contains('runtime DLLs'),
            contains(r'%LOCALAPPDATA%\Programs\Swift'),
          ),
        );
        expect(const LinuxSwiftToolchainHost().failureGuidance(status), isNull);
        expect(const MacOSSwiftToolchainHost().failureGuidance(status), isNull);
      });
    }

    for (final status in [
      0,
      1,
      -11,
      139,
      0xC0000005,
      0xC0000135 + 0x100000000,
    ]) {
      test('Windows does not invent DLL guidance for status $status', () {
        expect(
          const WindowsSwiftToolchainHost().failureGuidance(status),
          isNull,
        );
      });
    }
  });

  group('SwiftRequirement.requireMinimum', () {
    Future<void> requireFloor(String printed, (int, int)? minimum) =>
        SwiftRequirement(
          residualRunner(
            residualProcessHost(
              LinuxHost(),
              (_, _, _) async => ResidualChild(output: printed),
            ),
          ),
        ).requireMinimum(
          '/opt/swift/bin/swift',
          minimum,
          installGuidance: const LinuxSwiftToolchainHost().installGuidance,
        );

    for (final policy in const <SwiftToolchainHostInterface>[
      LinuxSwiftToolchainHost(),
      WindowsSwiftToolchainHost(),
    ]) {
      test('$policy rejects Swift 6.3 with an install hint', () async {
        await expectLater(
          requireFloor(
            'Swift version 6.3.3 (swift-6.3.3-RELEASE)\nTarget: x',
            policy.minimumSwift,
          ),
          throwsA(
            isA<XcrossError>().having(
              (error) => error.message,
              'message',
              allOf(
                contains('requires Swift 6.4 or newer'),
                contains('is 6.3'),
                contains('/opt/swift/bin/swift'),
                contains('swift.org/install'),
              ),
            ),
          ),
        );
      });

      test('$policy accepts Swift 6.4 and newer', () async {
        for (final printed in [
          'Swift version 6.4 (swift-6.4-RELEASE)',
          'Swift version 6.10-dev',
          'Swift version 7.0 (swift-7.0-RELEASE)',
          '',
        ]) {
          await expectLater(
            requireFloor(printed, policy.minimumSwift),
            completes,
          );
        }
      });
    }

    test('macOS defers to the Xcode-paired Swift', () async {
      expect(const MacOSSwiftToolchainHost().minimumSwift, isNull);
      await expectLater(
        requireFloor(
          'Apple Swift version 6.2.4 (swiftlang-6.2.4.1.4)',
          const MacOSSwiftToolchainHost().minimumSwift,
        ),
        completes,
      );
    });
  });

  group('SwiftRequirement.requireSiblingClang', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('xcross-swift-req-');
    });
    tearDown(() => temp.deleteSync(recursive: true));

    test('accepts a toolchain that ships its own clang', () async {
      final bin = Directory(p.join(temp.path, 'bin'))..createSync();
      final swift = File(p.join(bin.path, runner.hostExecutableName('swift')))
        ..createSync();
      File(p.join(bin.path, runner.hostExecutableName('clang'))).createSync();

      await expectLater(
        SwiftRequirement(runner).requireSiblingClang(swift.path),
        completes,
      );
    });

    test('rejects a toolchain with no sibling clang', () async {
      final bin = Directory(p.join(temp.path, 'bin'))..createSync();
      final swift = File(p.join(bin.path, runner.hostExecutableName('swift')))
        ..createSync();

      await expectLater(
        SwiftRequirement(runner).requireSiblingClang(swift.path),
        throwsA(
          isA<XcrossError>().having(
            (error) => error.message,
            'message',
            allOf(contains('no sibling clang'), contains('builtin headers')),
          ),
        ),
      );
    });

    test('defers an unresolvable path to the installer', () async {
      // Not this check's job to report: sdk_install produces a far more
      // detailed diagnostic for a broken toolchain path.
      await expectLater(
        SwiftRequirement(runner).requireSiblingClang(p.join(temp.path, 'gone')),
        completes,
      );
    });
  });
}

Future<String> _requireSwift(
  String action, {
  required ProcessRunner runner,
  required String installGuidance,
  required Future<String?> Function(String) locate,
  String? extra,
}) => SwiftRequirement(
  residualRunner(runner.host, lookup: (name, _) => locate(name)),
).require(action, installGuidance: installGuidance, extra: extra);
