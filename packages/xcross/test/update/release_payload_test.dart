import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/update/internal/release_payload.dart';

Archive _bundle({
  String binary = 'bin/xcross',
  Map<String, String> extra = const {},
}) {
  final archive = Archive()
    ..add(_entry(binary, 'binary'))
    ..add(_entry('lib/libsysv.so', 'library'));
  extra.forEach((name, contents) => archive.add(_entry(name, contents)));
  return archive;
}

ArchiveFile _entry(String name, String contents) {
  final bytes = utf8.encode(contents);
  return ArchiveFile.bytes(name, bytes);
}

List<int> _tarGz(Archive archive) =>
    const GZipEncoder().encodeBytes(TarEncoder().encodeBytes(archive));

List<int> _zip(Archive archive) => ZipEncoder().encodeBytes(archive);

void main() {
  late Directory destination;

  setUp(() {
    destination = Directory.systemTemp.createTempSync('xcross-payload-');
  });
  tearDown(() => destination.deleteSync(recursive: true));

  String read(String relative) =>
      File(p.join(destination.path, relative)).readAsStringSync();

  test('unpacks a tar.gz bundle', () async {
    await ReleasePayload(LinuxHost()).extract(
      bytes: _tarGz(_bundle()),
      asset: 'xcross-linux-x64.tar.gz',
      destination: destination.path,
      executableName: 'xcross',
    );

    expect(read(p.join('bin', 'xcross')), 'binary');
    expect(read(p.join('lib', 'libsysv.so')), 'library');
  });

  for (final asset in ['xcross-windows-x64.zip', 'xcross-windows-arm64.zip']) {
    test('unpacks a zip bundle from $asset', () async {
      await ReleasePayload(LinuxHost()).extract(
        bytes: _zip(_bundle(binary: 'bin/xcross.exe')),
        asset: asset,
        destination: destination.path,
        executableName: 'xcross.exe',
      );

      expect(read(p.join('bin', 'xcross.exe')), 'binary');
    });

    test('ignores the licence files $asset also ships', () async {
      await ReleasePayload(LinuxHost()).extract(
        bytes: _zip(
          _bundle(
            binary: 'bin/xcross.exe',
            extra: {
              'LICENSE': 'mit',
              'THIRD_PARTY_LICENSES/provision-dart.txt': 'notice',
            },
          ),
        ),
        asset: asset,
        destination: destination.path,
        executableName: 'xcross.exe',
      );

      expect(destination.listSync().map((e) => p.basename(e.path)).toSet(), {
        'bin',
        'lib',
      });
    });
  }

  test('refuses an entry that escapes the destination', () async {
    final archive = _bundle()..add(_entry('../../etc/passwd', 'pwned'));
    await expectLater(
      ReleasePayload(LinuxHost()).extract(
        bytes: _tarGz(archive),
        asset: 'xcross-linux-x64.tar.gz',
        destination: destination.path,
        executableName: 'xcross',
      ),
      throwsA(
        isA<XcrossError>().having(
          (e) => e.message,
          'message',
          contains('unsafe entry'),
        ),
      ),
    );
    expect(
      File(p.join(destination.parent.path, 'passwd')).existsSync(),
      isFalse,
    );
  });

  // A tar symlink entry still reports isFile, and its payload is a target path
  // rather than content, so writing it would yield a plausible empty binary.
  test('refuses a link entry masquerading as the binary', () async {
    final archive = Archive()
      ..add(ArchiveFile.symlink('bin/xcross', '/etc/passwd'))
      ..add(_entry('lib/libsysv.so', 'library'));
    await expectLater(
      ReleasePayload(LinuxHost()).extract(
        bytes: _tarGz(archive),
        asset: 'xcross-linux-x64.tar.gz',
        destination: destination.path,
        executableName: 'xcross',
      ),
      throwsA(
        isA<XcrossError>().having(
          (e) => e.message,
          'message',
          contains('link entry'),
        ),
      ),
    );
  });

  test('rejects a bundle whose executable is empty', () async {
    final archive = Archive()
      ..add(_entry('bin/xcross', ''))
      ..add(_entry('lib/libsysv.so', 'library'));
    await expectLater(
      ReleasePayload(LinuxHost()).extract(
        bytes: _tarGz(archive),
        asset: 'xcross-linux-x64.tar.gz',
        destination: destination.path,
        executableName: 'xcross',
      ),
      throwsA(isA<XcrossError>()),
    );
  });

  test('rejects a bundle with no executable', () async {
    final archive = Archive()..add(_entry('lib/libsysv.so', 'library'));
    await expectLater(
      ReleasePayload(LinuxHost()).extract(
        bytes: _tarGz(archive),
        asset: 'xcross-linux-x64.tar.gz',
        destination: destination.path,
        executableName: 'xcross',
      ),
      throwsA(
        isA<XcrossError>().having(
          (e) => e.message,
          'message',
          contains('missing bin/xcross'),
        ),
      ),
    );
  });

  test('rejects a bundle with no libraries', () async {
    final archive = Archive()..add(_entry('bin/xcross', 'binary'));
    await expectLater(
      ReleasePayload(LinuxHost()).extract(
        bytes: _tarGz(archive),
        asset: 'xcross-linux-x64.tar.gz',
        destination: destination.path,
        executableName: 'xcross',
      ),
      throwsA(
        isA<XcrossError>().having(
          (e) => e.message,
          'message',
          contains('missing its lib/ payload'),
        ),
      ),
    );
  });
}
