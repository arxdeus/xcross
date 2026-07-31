import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/grandslam/app_token_exchange.dart';
import 'package:xcross/src/grandslam/grandslam_session_store.dart';

void main() {
  late Directory tempDir;
  late String sessionPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('xcross_grandslam_session');
    sessionPath = p.join(tempDir.path, 'grandslam-session.json');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('save/load round-trips the Developer Services session', () async {
    final store = GrandSlamSessionStore(path: sessionPath);
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

    await store.save(session);
    final loaded = await store.load();

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

  test('load returns null when absent, clear deletes the file', () async {
    final store = GrandSlamSessionStore(path: sessionPath);
    expect(await store.load(), isNull);

    await store.save(
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

    await store.clear();
    expect(File(sessionPath).existsSync(), isFalse);
    expect(await store.load(), isNull);
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
