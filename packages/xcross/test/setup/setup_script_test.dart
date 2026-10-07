import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/host/shared/setup/posix_setup_script.dart';
import 'package:xcross/src/host/windows/setup/windows_setup_script.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/setup/setup_script.dart';

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
    runner = fixtureRunner(host, log: fixtureLog());
  });
  tearDown(() => temporary.deleteSync(recursive: true));

  test('Windows invokes PowerShell with exact script flags', () async {
    final powershell = File(p.join(temporary.path, 'powershell'))..createSync();
    final windowsRunner = fixtureRunner(
      LinuxHost(environment: {'PATH': temporary.path}),
      log: fixtureLog(),
    );
    final invocation = await WindowsSetupScript(
      host,
      windowsRunner,
    ).invocation('chosen script.ps1');
    expect(invocation.executable, powershell.path);
    expect(invocation.arguments, [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      'chosen script.ps1',
    ]);
  });

  test('Windows replacement parks the destination after a sharing failure', () {
    final destination = File(p.join(temporary.path, 'cache.ps1'))
      ..writeAsStringSync('old');
    final temporaryFile = File(p.join(temporary.path, 'next.ps1'))
      ..writeAsStringSync('new');
    WindowsSetupScript(
      host,
      runner,
    ).replace(FixtureSharingFailure(temporaryFile), destination);
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
        FixtureSharingFailure(temporaryFile, failPromotion: true),
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
    Map<String, String>? environment;
    SetupScriptApproval? shown;
    final manager = SetupScriptManager(
      createHttpClient: () =>
          throw StateError('unexpected fixture HTTP client'),
      source: script.path,
      host: host,
      runner: runner,
      policy: PosixSetupScript(host),
      execute: (value, args, env) async {
        executable = value;
        arguments = args;
        environment = env;
      },
    );

    final ran = await manager.run(
      approve: (candidate) {
        shown = candidate;
        return true;
      },
    );

    expect(ran, isTrue);
    expect(executable, '/bin/sh');
    expect(arguments, [script.path]);
    expect(environment, isEmpty);
    expect(shown!.name, 'setup.sh');
    expect(shown!.source, script.path);
    expect(shown!.sha256, sha256.convert(utf8.encode('echo setup')).toString());
  });

  test('declined approval never executes the script', () async {
    final script = File(p.join(temporary.path, 'setup.sh'))
      ..writeAsStringSync('echo setup');
    var executions = 0;
    final manager = SetupScriptManager(
      createHttpClient: () =>
          throw StateError('unexpected fixture HTTP client'),
      source: script.path,
      host: host,
      runner: runner,
      policy: PosixSetupScript(host),
      execute: (_, _, _) async => executions++,
    );

    expect(await manager.run(approve: (_) => false), isFalse);
    expect(executions, 0);
  });

  test('remote approval shows the URL without credentials', () async {
    SetupScriptApproval? shown;
    Map<String, String>? environment;
    final manager = SetupScriptManager(
      createHttpClient: () =>
          throw StateError('unexpected fixture HTTP client'),
      source: 'https://user:secret@example.com/setup/apt.sh?token=abc',
      host: host,
      runner: runner,
      policy: PosixSetupScript(host),
      download: (_) async => utf8.encode('echo remote'),
      execute: (_, _, env) async => environment = env,
    );

    await manager.run(
      approve: (candidate) {
        shown = candidate;
        return true;
      },
      assumeYes: true,
    );

    expect(shown!.name, 'apt.sh');
    expect(shown!.source, 'https://example.com/setup/apt.sh');
    expect(shown!.path, isNot(shown!.source));
    expect(environment, {'XCROSS_SETUP_ASSUME_YES': '1'});
  });

  test('refreshFirst falls back to the cached script offline', () async {
    var online = true;
    final manager = SetupScriptManager(
      createHttpClient: () =>
          throw StateError('unexpected fixture HTTP client'),
      source: 'https://example.com/setup.ps1',
      host: host,
      runner: runner,
      policy: PosixSetupScript(host),
      download: (_) async {
        if (!online) throw XcrossError('offline');
        return utf8.encode('cached');
      },
      execute: (_, _, _) async {},
    );
    await manager.refresh();
    online = false;

    String? sha;
    await manager.run(
      refreshFirst: true,
      approve: (candidate) {
        sha = candidate.sha256;
        return true;
      },
    );

    expect(sha, sha256.convert(utf8.encode('cached')).toString());
  });

  test('Windows defaults to the winget setup script', () {
    expect(
      WindowsSetupScript(host, runner).defaultSource,
      endsWith('/setup/winget.ps1'),
    );
    expect(
      WindowsSetupScript.scriptUrl('v1.2.3'),
      'https://raw.githubusercontent.com/arxdeus/xcross/v1.2.3/setup/winget.ps1',
    );
    expect(PosixSetupScript(host).defaultSource, isNull);
  });

  test(
    'caches remote scripts by content hash and reuses current content',
    () async {
      final bytes = utf8.encode('#!/bin/sh\necho setup\n');
      var downloads = 0;
      final manager = SetupScriptManager(
        createHttpClient: () =>
            throw StateError('unexpected fixture HTTP client'),
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
      createHttpClient: () =>
          throw StateError('unexpected fixture HTTP client'),
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
      createHttpClient: () =>
          throw StateError('unexpected fixture HTTP client'),
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

  test(
    'wraps injected download transport failures and closes client',
    () async {
      final client = FixtureSetupHttpClient(
        (_) async => throw http.ClientException('fixture denied'),
      );
      final manager = SetupScriptManager(
        createHttpClient: () => client,
        source: 'https://fixture.invalid/setup.sh',
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
            contains('Failed to download configured setup script from'),
          ),
        ),
      );
      expect(client.closed, isTrue);
    },
  );

  test(
    'uses configured HTTP client for success without native transport',
    () async {
      final client = FixtureSetupHttpClient(
        (_) async => http.Response('echo fixture', 200),
      );
      final manager = SetupScriptManager(
        createHttpClient: () => client,
        source: 'https://fixture.invalid/setup.sh',
        host: host,
        runner: runner,
        policy: PosixSetupScript(host),
      );
      expect((await manager.resolve())!.readAsStringSync(), 'echo fixture');
      expect(client.closed, isTrue);
    },
  );

  test('rejects injected HTTP error and closes client', () async {
    final client = FixtureSetupHttpClient(
      (_) async => http.Response('denied', 403),
    );
    final manager = SetupScriptManager(
      createHttpClient: () => client,
      source: 'https://fixture.invalid/setup.sh',
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
          contains('HTTP 403'),
        ),
      ),
    );
    expect(client.closed, isTrue);
  });

  test('rejects injected HTTP timeout and closes client', () async {
    final client = FixtureSetupHttpClient(
      (_) async => throw TimeoutException('fixture timeout'),
    );
    final manager = SetupScriptManager(
      createHttpClient: () => client,
      source: 'https://fixture.invalid/setup.sh',
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
          contains('request timed out'),
        ),
      ),
    );
    expect(client.closed, isTrue);
  });

  test('refresh downloads content and advances the cached hash', () async {
    var payload = utf8.encode('one');
    final manager = SetupScriptManager(
      createHttpClient: () =>
          throw StateError('unexpected fixture HTTP client'),
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

@internal
final class FixtureSharingFailure implements File {
  FixtureSharingFailure(this.file, {this.failPromotion = false});
  final File file;
  final bool failPromotion;
  int attempts = 0;
  @override
  String get path => file.path;
  @override
  File renameSync(String destination) {
    attempts++;
    if (attempts == 1 || failPromotion) {
      throw FileSystemException('fixture sharing violation', path);
    }
    return file.renameSync(destination);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

@internal
final class FixtureSetupHttpClient extends MockClient {
  FixtureSetupHttpClient(super.handler);
  bool closed = false;
  @override
  void close() {
    closed = true;
    super.close();
  }
}
