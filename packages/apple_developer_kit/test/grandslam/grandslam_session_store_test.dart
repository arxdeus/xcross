import 'dart:io';

import 'package:apple_developer_kit/src/errors.dart';
import 'package:apple_developer_kit/src/grandslam/app_token_exchange.dart';
import 'package:apple_developer_kit/src/grandslam/grandslam_session_store.dart';
import 'package:apple_developer_kit/src/secure/local_cipher.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/host_services.dart';

void main() {
  late Directory tempDir;
  late String sessionPath;

  // Pinned so tests never touch the developer's real config directory and
  // never depend on the host having a readable machine id.
  LocalCipher cipher() => LocalCipher(
    keyFilePath: p.join(tempDir.path, 'local.key'),
    machineId: 'test-machine',
    hostServices: testHostServices,
  );

  GrandSlamSessionStore store() => GrandSlamSessionStore(
    path: sessionPath,
    cipher: cipher(),
    hostServices: testHostServices,
  );

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('xcross_grandslam_session');
    sessionPath = p.join(tempDir.path, 'grandslam-session.json');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('save/load round-trips the Developer Services session', () async {
    final session = GrandSlamSession(
      username: 'User@Example.com',
      teamId: 'TEAM123',
      adiLibraryDirectory: tempDir.absolute.path,
      token: DeveloperServicesLoginToken(
        adsid: '123456789',
        token: 'developer-token',
        expiry: DateTime.fromMillisecondsSinceEpoch(1893456000000, isUtc: true),
      ),
    );

    await store().save(session);
    final loaded = await store().load();

    expect(loaded, isNotNull);
    expect(loaded!.username, session.username);
    expect(loaded.teamId, session.teamId);
    expect(loaded.adiLibraryDirectory, session.adiLibraryDirectory);
    expect(loaded.token.adsid, session.token.adsid);
    expect(loaded.token.token, session.token.token);
    expect(loaded.token.expiry, session.token.expiry);
    expect(loaded.isExpired, isFalse);
    if (!Platform.isWindows) {
      expect(
        FileStat.statSync(sessionPath).modeString(),
        endsWith('rw-------'),
      );
    }
  });

  test('round-trips a session without adiLibraryDirectory', () async {
    await store().save(
      GrandSlamSession(
        username: 'windows@example.com',
        teamId: 'TEAM123',
        token: DeveloperServicesLoginToken(
          adsid: '1',
          token: 'token',
          expiry: DateTime.now().toUtc().add(const Duration(days: 1)),
        ),
      ),
    );

    final loaded = await store().load();
    expect(loaded?.adiLibraryDirectory, isNull);
    expect(loaded?.teamId, 'TEAM123');
  });

  test('invalid JSON errors do not echo persisted token material', () async {
    await File(sessionPath).writeAsString('{"token":"secret-token",BROKEN');

    await expectLater(
      store().load(),
      throwsA(
        isA<AppleError>().having(
          (error) => error.toString(),
          'message',
          isNot(contains('secret-token')),
        ),
      ),
    );
  });

  test('load returns null when absent, clear deletes the file', () async {
    expect(await store().load(), isNull);

    await store().save(
      GrandSlamSession(
        username: 'user@example.com',
        teamId: 'TEAM123',
        adiLibraryDirectory: tempDir.absolute.path,
        token: DeveloperServicesLoginToken(
          adsid: '1',
          token: 'token',
          expiry: DateTime.now().toUtc().add(const Duration(days: 1)),
        ),
      ),
    );
    expect(File(sessionPath).existsSync(), isTrue);

    await store().clear();
    expect(File(sessionPath).existsSync(), isFalse);
    expect(await store().load(), isNull);
  });

  test('the token never reaches disk in cleartext', () async {
    await store().save(
      GrandSlamSession(
        username: 'user@example.com',
        teamId: 'TEAM123',
        token: DeveloperServicesLoginToken(
          adsid: '123456789',
          token: 'super-secret-token',
          expiry: DateTime.now().toUtc().add(const Duration(days: 1)),
        ),
      ),
    );

    final onDisk = File(sessionPath).readAsStringSync();
    expect(onDisk, isNot(contains('super-secret-token')));
    expect(onDisk, isNot(contains('user@example.com')));
    expect(onDisk, isNot(contains('123456789')));
    expect(LocalCipher.isSealed(onDisk), isTrue);
  });

  test('a session sealed on another machine is refused', () async {
    await store().save(
      GrandSlamSession(
        username: 'user@example.com',
        teamId: 'TEAM123',
        token: DeveloperServicesLoginToken(
          adsid: '1',
          token: 'token',
          expiry: DateTime.now().toUtc().add(const Duration(days: 1)),
        ),
      ),
    );

    final elsewhere = GrandSlamSessionStore(
      path: sessionPath,
      cipher: LocalCipher(
        keyFilePath: p.join(tempDir.path, 'local.key'),
        machineId: 'a-different-machine',
        hostServices: testHostServices,
      ),
      hostServices: testHostServices,
    );
    await expectLater(elsewhere.load(), throwsA(isA<LocalCipherError>()));
  });

  test('a legacy cleartext session is read once, then resealed', () async {
    await File(sessionPath).writeAsString(
      '{"username":"user@example.com","adsid":"1","token":"legacy-token",'
      '"expiryMs":1893456000000,"teamId":"TEAM123"}',
    );

    final loaded = await store().load();
    expect(loaded?.token.token, 'legacy-token');

    final onDisk = File(sessionPath).readAsStringSync();
    expect(LocalCipher.isSealed(onDisk), isTrue);
    expect(onDisk, isNot(contains('legacy-token')));
    expect((await store().load())?.token.token, 'legacy-token');
  });

  test('isExpired delegates to the persisted token expiry', () {
    final session = GrandSlamSession(
      username: 'user@example.com',
      teamId: 'TEAM123',
      adiLibraryDirectory: tempDir.absolute.path,
      token: DeveloperServicesLoginToken(
        adsid: '1',
        token: 'token',
        expiry: DateTime.now().toUtc().subtract(const Duration(seconds: 1)),
      ),
    );

    expect(session.isExpired, isTrue);
  });
}
