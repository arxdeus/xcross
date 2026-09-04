import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/cli/basic/internal/swift_requirement.dart';
import 'package:xcross/src/errors.dart';

void main() {
  group('SwiftRequirement.require', () {
    test('returns the located toolchain when Swift is on PATH', () async {
      expect(
        await SwiftRequirement.require(
          'install the Darwin SDK',
          locate: (name) async => '/opt/swift/bin/$name',
        ),
        '/opt/swift/bin/${ProcessRunner.hostExecutableName('swift')}',
      );
    });

    test('names the action and how to verify the fix', () async {
      await expectLater(
        SwiftRequirement.require(
          'install the Darwin SDK',
          locate: (_) async => null,
          platformName: 'linux',
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
      Future<String> hintFor(String platform) async {
        try {
          await SwiftRequirement.require(
            'set up this host',
            locate: (_) async => null,
            platformName: platform,
          );
        } on XcrossError catch (error) {
          return error.message;
        }
        fail('expected a missing-Swift failure for $platform');
      }

      expect(await hintFor('windows'), contains('install/windows'));
      expect(await hintFor('macos'), contains('install/macos'));
      // An unknown host still gets the generic instruction rather than
      // an empty line where the fix should be.
      expect(await hintFor('haiku'), contains('swift.org/install/'));
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
      final swift = File(
        p.join(bin.path, ProcessRunner.hostExecutableName('swift')),
      )..createSync();
      File(
        p.join(bin.path, ProcessRunner.hostExecutableName('clang')),
      ).createSync();

      await expectLater(
        SwiftRequirement.requireSiblingClang(swift.path),
        completes,
      );
    });

    test('rejects a toolchain with no sibling clang', () async {
      final bin = Directory(p.join(temp.path, 'bin'))..createSync();
      final swift = File(
        p.join(bin.path, ProcessRunner.hostExecutableName('swift')),
      )..createSync();

      await expectLater(
        SwiftRequirement.requireSiblingClang(swift.path),
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
        SwiftRequirement.requireSiblingClang(p.join(temp.path, 'gone')),
        completes,
      );
    });
  });
}
