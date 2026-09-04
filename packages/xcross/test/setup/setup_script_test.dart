import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/setup/setup_script.dart';

void main() {
  late Directory temporary;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('xcross-setup-script-');
  });
  tearDown(() => temporary.deleteSync(recursive: true));

  test('runs a configured local script through the host shell', () async {
    final script = File(p.join(temporary.path, 'setup.sh'))
      ..writeAsStringSync('echo setup');
    String? executable;
    List<String>? arguments;
    final manager = SetupScriptManager(
      source: script.path,
      environment: {'HOME': temporary.path},
      windows: false,
      execute: (value, args) async {
        executable = value;
        arguments = args;
      },
    );

    await manager.run();

    expect(executable, '/bin/sh');
    expect(arguments, [script.path]);
  });

  test(
    'caches remote scripts by content hash and reuses current content',
    () async {
      final bytes = utf8.encode('#!/bin/sh\necho setup\n');
      var downloads = 0;
      final manager = SetupScriptManager(
        source: 'https://example.com/setup.sh',
        environment: {'XDG_CACHE_HOME': temporary.path},
        windows: false,
        download: (_) async {
          downloads++;
          return bytes;
        },
      );

      final first = await manager.resolve();
      final second = await manager.resolve();

      expect(downloads, 1);
      expect(first!.path, second!.path);
      expect(p.basename(first.path), '${sha256.convert(bytes)}.sh');
      expect(first.readAsBytesSync(), bytes);
    },
  );

  test('rejects an invalid cached pointer and downloads again', () async {
    final bytes = utf8.encode('echo setup');
    var downloads = 0;
    final manager = SetupScriptManager(
      source: 'https://example.com/setup.sh',
      environment: {'XDG_CACHE_HOME': temporary.path},
      windows: false,
      download: (_) async {
        downloads++;
        return bytes;
      },
    );

    await manager.resolve();
    final pointer = temporary
        .listSync(recursive: true)
        .whereType<File>()
        .singleWhere((file) => file.path.endsWith('.current'));
    pointer.writeAsStringSync(sha256.convert(bytes).toString().toUpperCase());

    final resolved = await manager.resolve();

    expect(downloads, 2);
    expect(resolved!.readAsBytesSync(), bytes);
    expect(pointer.readAsStringSync(), sha256.convert(bytes).toString());
  });

  test('rejects cached content whose digest does not match', () async {
    final bytes = utf8.encode('echo setup');
    var downloads = 0;
    final manager = SetupScriptManager(
      source: 'https://example.com/setup.sh',
      environment: {'XDG_CACHE_HOME': temporary.path},
      windows: false,
      download: (_) async {
        downloads++;
        return bytes;
      },
    );

    final cached = await manager.resolve();
    cached!.writeAsStringSync('corrupt');

    final resolved = await manager.resolve();

    expect(downloads, 2);
    expect(resolved!.path, cached.path);
    expect(resolved.readAsBytesSync(), bytes);
  });

  test('wraps download transport failures in a user-facing error', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    await server.close(force: true);
    final manager = SetupScriptManager(
      source: 'http://localhost:$port/setup.sh',
      environment: {'XDG_CACHE_HOME': temporary.path},
      windows: false,
    );

    await expectLater(
      manager.resolve(),
      throwsA(
        isA<XcrossError>().having(
          (error) => error.message,
          'message',
          allOf(
            contains('Failed to download configured setup script from'),
            contains('/setup.sh'),
          ),
        ),
      ),
    );
  });

  test('refresh downloads content and advances the cached hash', () async {
    var payload = utf8.encode('one');
    final manager = SetupScriptManager(
      source: 'https://example.com/setup.sh',
      environment: {'XDG_CACHE_HOME': temporary.path},
      windows: false,
      download: (_) async => payload,
    );

    final first = await manager.refresh();
    payload = utf8.encode('two');
    final second = await manager.refresh();

    expect(first!.path, isNot(second!.path));
    expect(first.existsSync(), isTrue);
    expect(second.existsSync(), isTrue);
    expect((await manager.resolve())!.path, second.path);
  });
}
