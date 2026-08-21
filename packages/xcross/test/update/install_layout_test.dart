import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/update/install_layout.dart';

String _exeName() => Platform.isWindows ? 'xcross.exe' : 'xcross';

void main() {
  late Directory prefix;

  setUp(() {
    prefix = Directory.systemTemp.createTempSync('xcross-layout-');
    Directory(p.join(prefix.path, 'bin')).createSync();
    Directory(p.join(prefix.path, 'lib')).createSync();
    File(p.join(prefix.path, 'bin', _exeName())).writeAsStringSync('binary');
    File(
      p.join(prefix.path, 'lib', 'libsysv_abi_bridge.so'),
    ).writeAsStringSync('lib');
  });

  tearDown(() => prefix.deleteSync(recursive: true));

  test('derives lib/ as the sibling of bin/', () {
    final layout = InstallLayout.forExecutable(
      p.join(prefix.path, 'bin', _exeName()),
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

    final layout = InstallLayout.forExecutable(link.path);
    expect(p.basename(layout.binDir), 'bin');
    expect(
      layout.binaryPath,
      File(p.join(prefix.path, 'bin', _exeName())).resolveSymbolicLinksSync(),
    );
  }, onPlatform: const {'windows': Skip('symlinks need elevation')});

  test('refuses a dart run checkout', () {
    final dart = File(p.join(prefix.path, 'bin', 'dart'))
      ..writeAsStringSync('vm');
    expect(
      () => InstallLayout.forExecutable(dart.path),
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
  test('refuses a sibling lib/ that holds no native libraries', () {
    final lib = Directory(p.join(prefix.path, 'lib'));
    lib.deleteSync(recursive: true);
    lib.createSync();
    File(p.join(lib.path, 'xcross.dart')).writeAsStringSync('library;');
    expect(
      () => InstallLayout.forExecutable(p.join(prefix.path, 'bin', _exeName())),
      throwsA(
        isA<XcrossError>().having(
          (e) => e.message,
          'message',
          contains('unrecognised xcross installation'),
        ),
      ),
    );
  });

  test('refuses a layout with no sibling lib/', () {
    Directory(p.join(prefix.path, 'lib')).deleteSync(recursive: true);
    expect(
      () => InstallLayout.forExecutable(p.join(prefix.path, 'bin', _exeName())),
      throwsA(
        isA<XcrossError>().having(
          (e) => e.message,
          'message',
          contains('unrecognised xcross installation'),
        ),
      ),
    );
  });

  test('reports a user-owned temp prefix as writable', () {
    final layout = InstallLayout.forExecutable(
      p.join(prefix.path, 'bin', _exeName()),
    );
    expect(layout.isWritable, isTrue);
    expect(Directory(layout.binDir).listSync().map((e) => p.basename(e.path)), [
      _exeName(),
    ], reason: 'the write probe must not leave anything behind');
  });
}
