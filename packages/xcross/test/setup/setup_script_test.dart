import 'dart:convert';
import 'dart:io';
import 'package:cli_kit/cli_kit.dart';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/host/shared/setup/posix_setup_script.dart';
import 'package:xcross/src/host/windows/setup/windows_setup_script.dart';
import 'package:xcross/src/setup/setup_script.dart';
import '../host_operations_fixtures.dart';

void main() {
  late Directory temporary;
  late LinuxHost host;
  late ProcessRunner runner;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('xcross-setup-script-');
    host = LinuxHost(
      environment: {'XDG_CACHE_HOME': temporary.path, 'HOME': temporary.path},
    );
    runner = ProcessRunner(host, log: fixtureLog());
  });
  tearDown(() => temporary.deleteSync(recursive: true));

  test('Windows invokes PowerShell with exact script flags', () async {
    final powershell = File(p.join(temporary.path, 'powershell'))..createSync();
    final windowsRunner = ProcessRunner(
      LinuxHost(environment: {'PATH': temporary.path}),
      log: fixtureLog(),
    );
    final invocation = await WindowsSetupScript(
      host,
      windowsRunner,
    ).invocation('chosen script.ps1');
    expect(invocation.executable, powershell.path);
    expect(invocation.arguments, ['-NoProfile', '-File', 'chosen script.ps1']);
  });

  test('Windows replacement parks the destination after a sharing failure', () {
    final destination = File(p.join(temporary.path, 'cache.ps1'))
      ..writeAsStringSync('old');
    final temporaryFile = File(p.join(temporary.path, 'next.ps1'))
      ..writeAsStringSync('new');
    WindowsSetupScript(
      host,
      runner,
    ).replace(_SharingFailure(temporaryFile), destination);
    expect(destination.readAsStringSync(), 'new');
    expect(
      temporary.listSync().where((entry) => entry.path.endsWith('.bak')),
      isEmpty,
    );
  });

  test('Windows replacement restores parked script when promotion fails', () {
    final destination = File(p.join(temporary.path, 'cache.ps1'))
      ..writeAsStringSync('old');
    final temporaryFile = File(p.join(temporary.path, 'next.ps1'))
      ..writeAsStringSync('new');
    expect(
      () => WindowsSetupScript(host, runner).replace(
        _SharingFailure(temporaryFile, failPromotion: true),
        destination,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(destination.readAsStringSync(), 'old');
    expect(temporaryFile.readAsStringSync(), 'new');
    expect(
      temporary.listSync().where((entry) => entry.path.endsWith('.bak')),
      isEmpty,
    );
  });

  test('runs a configured local script through the host shell', () async {
    final script = File(p.join(temporary.path, 'setup.sh'))
      ..writeAsStringSync('echo setup');
    String? executable;
    List<String>? arguments;
    final manager = SetupScriptManager(
      source: script.path,
      host: host,
      runner: runner,
      policy: PosixSetupScript(host),
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
        host: host,
        runner: runner,
        policy: PosixSetupScript(host),
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
      host: host,
      runner: runner,
      policy: PosixSetupScript(host),
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
      host: host,
      runner: runner,
      policy: PosixSetupScript(host),
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
      host: host,
      runner: runner,
      policy: PosixSetupScript(host),
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
      host: host,
      runner: runner,
      policy: PosixSetupScript(host),
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

final class _SharingFailure implements File {
  _SharingFailure(this.file, {this.failPromotion = false});
  final File file;
  final bool failPromotion;
  int attempts = 0;
  @override
  String get path => file.path;
  @override
  File renameSync(String destination) {
    attempts++;
    if (attempts == 1 || failPromotion)
      throw FileSystemException('fixture sharing violation', path);
    return file.renameSync(destination);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
