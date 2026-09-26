import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/update/internal/dart_executable_resolver.dart';

void main() {
  group('findDartExecutableOnPath', () {
    test(
      'Windows accepts dart.exe and ignores an extensionless script',
      () async {
        final bin = _createBinDirectory();
        File(p.join(bin.path, 'dart')).writeAsStringSync('#!/bin/bash\n');
        File(p.join(bin.path, 'dart.EXE')).createSync();

        final result = await findDartExecutableOnPath(
          windows: true,
          environment: _windowsEnvironment(bin),
          useConfiguration: false,
        );

        expect(result, p.join(bin.path, 'dart.EXE'));
      },
    );

    test('Windows accepts dart.bat when no dart.exe is available', () async {
      final bin = _createBinDirectory();
      File(p.join(bin.path, 'dart')).writeAsStringSync('#!/bin/bash\n');
      File(p.join(bin.path, 'dart.BAT')).createSync();

      final result = await findDartExecutableOnPath(
        windows: true,
        environment: _windowsEnvironment(bin),
        useConfiguration: false,
      );

      expect(result, p.join(bin.path, 'dart.BAT'));
    });

    test(
      'Windows rejects an extensionless launcher without a Windows file',
      () async {
        final bin = _createBinDirectory();
        File(p.join(bin.path, 'dart')).writeAsStringSync('#!/bin/bash\n');

        await expectLater(
          findDartExecutableOnPath(
            windows: true,
            environment: _windowsEnvironment(bin),
            useConfiguration: false,
          ),
          throwsA(
            isA<XcrossError>().having(
              (error) => error.message,
              'message',
              contains('required executable "dart"'),
            ),
          ),
        );
      },
    );

    test('Linux resolves only the exact dart file', () async {
      final bin = _createBinDirectory();
      final dart = File(p.join(bin.path, 'dart'))..createSync();
      expect(Process.runSync('chmod', ['755', dart.path]).exitCode, 0);
      File(p.join(bin.path, 'dart.exe')).createSync();
      File(p.join(bin.path, 'dart.bat')).createSync();

      final result = await findDartExecutableOnPath(
        windows: false,
        environment: _linuxEnvironment(bin),
        useConfiguration: false,
      );

      expect(result, dart.path);
    }, skip: Platform.isWindows);

    test('Linux skips a non-executable dart earlier on PATH', () async {
      final firstBin = _createBinDirectory();
      final secondBin = _createBinDirectory();
      final unusable = File(p.join(firstBin.path, 'dart'))..createSync();
      final usable = File(p.join(secondBin.path, 'dart'))..createSync();
      expect(Process.runSync('chmod', ['644', unusable.path]).exitCode, 0);
      expect(Process.runSync('chmod', ['755', usable.path]).exitCode, 0);

      final result = await findDartExecutableOnPath(
        windows: false,
        environment: {'PATH': '${firstBin.path}:${secondBin.path}'},
        useConfiguration: false,
      );

      expect(result, usable.path);
    }, skip: Platform.isWindows);

    test(
      'Linux skips a dart the current user cannot execute',
      () async {
        final firstBin = _createBinDirectory();
        final secondBin = _createBinDirectory();
        final othersOnly = File(p.join(firstBin.path, 'dart'))..createSync();
        final usable = File(p.join(secondBin.path, 'dart'))..createSync();
        expect(Process.runSync('chmod', ['011', othersOnly.path]).exitCode, 0);
        expect(Process.runSync('chmod', ['755', usable.path]).exitCode, 0);

        final result = await findDartExecutableOnPath(
          windows: false,
          environment: {'PATH': '${firstBin.path}:${secondBin.path}'},
          useConfiguration: false,
        );

        expect(result, usable.path);
      },
      skip: Platform.isWindows || _isRoot()
          ? 'needs a non-root POSIX user'
          : false,
    );

    test(
      'Linux resolves a relative PATH entry to an absolute dart path',
      () async {
        final bin = _createBinDirectory();
        final dart = File(p.join(bin.path, 'dart'))..createSync();
        expect(Process.runSync('chmod', ['755', dart.path]).exitCode, 0);
        final relativeBin = p.relative(bin.path, from: Directory.current.path);

        final result = await findDartExecutableOnPath(
          windows: false,
          environment: {'PATH': relativeBin},
          useConfiguration: false,
        );

        expect(p.isAbsolute(result), isTrue);
        expect(p.equals(result, dart.path), isTrue);
      },
      skip: Platform.isWindows,
    );

    test('Linux keeps a symlinked PATH entry with .. unnormalized', () async {
      final root = _createBinDirectory();
      final target = Directory(p.join(root.path, 'real', 'nested'))
        ..createSync(recursive: true);
      final realBin = Directory(p.join(root.path, 'real', 'bin'))..createSync();
      final dart = File(p.join(realBin.path, 'dart'))..createSync();
      expect(Process.runSync('chmod', ['755', dart.path]).exitCode, 0);
      Link(p.join(root.path, 'link')).createSync(target.path);
      final entry = p.join(root.path, 'link', '..', 'bin');

      final result = await findDartExecutableOnPath(
        windows: false,
        environment: {'PATH': entry},
        useConfiguration: false,
      );

      expect(result, p.join(entry, 'dart'));
      expect(File(result).existsSync(), isTrue);
      expect(
        File(result).resolveSymbolicLinksSync(),
        dart.resolveSymbolicLinksSync(),
      );
    }, skip: Platform.isWindows);

    test('Linux does not resolve Windows-only launcher files', () async {
      final bin = _createBinDirectory();
      File(p.join(bin.path, 'dart.exe')).createSync();
      File(p.join(bin.path, 'dart.bat')).createSync();

      await expectLater(
        findDartExecutableOnPath(
          windows: false,
          environment: _linuxEnvironment(bin),
          useConfiguration: false,
        ),
        throwsA(isA<XcrossError>()),
      );
    });
  });
}

Directory _createBinDirectory() {
  final directory = Directory.systemTemp.createTempSync(
    'dart-executable-resolver-test-',
  );
  addTearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });
  return directory;
}

Map<String, String> _windowsEnvironment(Directory bin) => {
  'PATH': bin.path,
  'PATHEXT': '.EXE;.BAT;.CMD',
};

Map<String, String> _linuxEnvironment(Directory bin) => {'PATH': bin.path};

bool _isRoot() =>
    (Process.runSync('id', ['-u']).stdout as String).trim() == '0';
