import 'dart:io';

import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/update/install_layout.dart';

import '../host_operations_fixtures.dart';

String _exeName() => Platform.isWindows ? 'xcross.exe' : 'xcross';

void main() {
  late Directory prefix;

  setUp(() {
    prefix = Directory(
      Directory.systemTemp
          .createTempSync('install-layout-test-')
          .resolveSymbolicLinksSync(),
    );
    Directory(p.join(prefix.path, 'bin')).createSync();
    Directory(p.join(prefix.path, 'lib')).createSync();
    File(p.join(prefix.path, 'bin', _exeName())).writeAsStringSync('binary');
    File(
      p.join(prefix.path, 'lib', 'libsysv_abi_bridge.so'),
    ).writeAsStringSync('lib');
  });

  tearDown(() {
    try {
      prefix.deleteSync(recursive: true);
    } on PathNotFoundException {
      if (prefix.existsSync()) rethrow;
    }
  });

  test(
    testOn: '!windows',

    'layout observations and write probes use the supplied mapped filesystem',
    () {
      final mapped = FixtureMappedFileSystem(prefix);
      Directory(mapped.physical('/logical/bin')).createSync(recursive: true);
      Directory(mapped.physical('/logical/lib')).createSync(recursive: true);
      File(mapped.physical('/logical/bin/xcross')).writeAsStringSync('binary');
      File(
        mapped.physical('/logical/lib/fixture.so'),
      ).writeAsStringSync('library');
      final host = LinuxHost(fileSystem: mapped);
      final layout = InstallLayout.forExecutable(
        '/logical/bin/xcross',
        host: host,
      );
      expect(layout.binaryPath, mapped.physical('/logical/bin/xcross'));
      expect(layout.hasNativeLibraries, isTrue);
      expect(layout.isWritable, isTrue);
      expect(
        mapped.touched,
        containsAll([
          '/logical/bin/xcross',
          mapped.physical('/logical/lib'),
          mapped.physical('/logical/bin/.xcross-write-probe-$pid'),
          mapped.physical('/logical/lib/.xcross-write-probe-$pid'),
        ]),
      );
      expect(
        Directory(mapped.physical('/logical/bin')).listSync(),
        hasLength(1),
      );
    },
  );

  test(testOn: '!windows', 'derives lib/ as the sibling of bin/', () {
    final layout = InstallLayout.forExecutable(
      p.join(prefix.path, 'bin', _exeName()),
      host: LinuxHost(),
    );
    expect(p.basename(layout.binDir), 'bin');
    expect(p.basename(layout.libDir), 'lib');
    expect(p.dirname(layout.binDir), p.dirname(layout.libDir));
    expect(File(layout.binaryPath).existsSync(), isTrue);
  });

  test('resolves a symlink so the real file is the update target', () {
    final linkDir = Directory(p.join(prefix.path, 'link'))..createSync();
    final link = Link(p.join(linkDir.path, _exeName()))
      ..createSync(p.join(prefix.path, 'bin', _exeName()));

    final layout = InstallLayout.forExecutable(link.path, host: LinuxHost());
    expect(p.basename(layout.binDir), 'bin');
    expect(
      layout.binaryPath,
      File(p.join(prefix.path, 'bin', _exeName())).resolveSymbolicLinksSync(),
    );
  }, onPlatform: const {'windows': Skip('symlinks need elevation')});

  test(testOn: '!windows', 'refuses a dart run checkout', () {
    final dart = File(p.join(prefix.path, 'bin', 'dart'))
      ..writeAsStringSync('vm');
    expect(
      () => InstallLayout.forExecutable(dart.path, host: LinuxHost()),
      throwsA(
        isA<XcrossError>().having(
          (e) => e.message,
          'message',
          contains('source checkout'),
        ),
      ),
    );
  });

  // `dart compile exe -o packages/xcross/bin/xcross` in a source checkout also
  // yields a sibling lib/, holding the package's Dart sources.
  test(
    testOn: '!windows',
    'refuses a sibling lib/ that only holds non-native files',
    () {
      final lib = Directory(p.join(prefix.path, 'lib'));
      lib.deleteSync(recursive: true);
      lib.createSync();
      File(p.join(lib.path, 'xcross.dart')).writeAsStringSync('library;');
      expect(
        () => InstallLayout.forExecutable(
          p.join(prefix.path, 'bin', _exeName()),
          host: LinuxHost(),
        ),
        throwsA(
          isA<XcrossError>().having(
            (e) => e.message,
            'message',
            contains('unrecognised xcross installation'),
          ),
        ),
      );
    },
  );

  test('accepts an empty lib/ so update can repair missing libraries', () {
    final lib = Directory(p.join(prefix.path, 'lib'));
    lib.deleteSync(recursive: true);
    lib.createSync();

    final layout = InstallLayout.forExecutable(
      p.join(prefix.path, 'bin', _exeName()),
      host: LinuxHost(),
    );

    expect(layout.hasNativeLibraries, isFalse);
  });

  test(testOn: '!windows', 'reports installed native libraries', () {
    final layout = InstallLayout.forExecutable(
      p.join(prefix.path, 'bin', _exeName()),
      host: LinuxHost(),
    );

    expect(layout.hasNativeLibraries, isTrue);
  });

  test(testOn: '!windows', 'refuses a layout with no sibling lib/', () {
    Directory(p.join(prefix.path, 'lib')).deleteSync(recursive: true);
    expect(
      () => InstallLayout.forExecutable(
        p.join(prefix.path, 'bin', _exeName()),
        host: LinuxHost(),
      ),
      throwsA(
        isA<XcrossError>().having(
          (e) => e.message,
          'message',
          contains('unrecognised xcross installation'),
        ),
      ),
    );
  });

  test(testOn: '!windows', 'reports a user-owned temp prefix as writable', () {
    final layout = InstallLayout.forExecutable(
      p.join(prefix.path, 'bin', _exeName()),
      host: LinuxHost(),
    );
    expect(layout.isWritable, isTrue);
    expect(Directory(layout.binDir).listSync().map((e) => p.basename(e.path)), [
      _exeName(),
    ], reason: 'the write probe must not leave anything behind');
  });
}
