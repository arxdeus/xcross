import 'dart:convert';
import 'dart:io';

import 'package:apple_developer_kit/src/shared/secure/local_cipher.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/host_services.dart';

void main() {
  late Directory tempDir;
  late String keyPath;

  LocalCipher cipher({String machineId = 'machine-a', String? keyFilePath}) =>
      LocalCipher(
        keyFilePath: keyFilePath ?? keyPath,
        machineId: machineId,
        hostServices: testHostServices,
      );

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('xcross_local_cipher');
    keyPath = p.join(tempDir.path, 'local.key');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('seal/open round-trips across instances', () async {
    final sealed = await cipher().seal('{"token":"abc"}');
    expect(await cipher().open(sealed), '{"token":"abc"}');
  });

  test('the ciphertext leaks neither plaintext nor key', () async {
    final sealed = await cipher().seal('super-secret-token');
    expect(sealed, isNot(contains('super-secret-token')));
    expect(sealed, isNot(contains(File(keyPath).readAsStringSync().trim())));
    expect(LocalCipher.isSealed(sealed), isTrue);
  });

  test('nonces are per-seal, so identical inputs differ on disk', () async {
    final instance = cipher();
    expect(await instance.seal('same'), isNot(await instance.seal('same')));
  });

  test('a different machine id cannot open the envelope', () async {
    final sealed = await cipher().seal('secret');
    await expectLater(
      cipher(machineId: 'machine-b').open(sealed),
      throwsA(isA<LocalCipherError>()),
    );
  });

  test('a different key file cannot open the envelope', () async {
    final sealed = await cipher().seal('secret');
    await expectLater(
      cipher(keyFilePath: p.join(tempDir.path, 'other.key')).open(sealed),
      throwsA(isA<LocalCipherError>()),
    );
  });

  test('tampering with the ciphertext is detected', () async {
    final doc =
        jsonDecode(await cipher().seal('secret')) as Map<String, Object?>;
    final data = base64.decode(doc['data']! as String);
    data[0] ^= 0xff;
    doc['data'] = base64.encode(data);

    await expectLater(
      cipher().open(jsonEncode(doc)),
      throwsA(isA<LocalCipherError>()),
    );
  });

  test('non-envelopes are not mistaken for sealed data', () async {
    for (final plain in [
      'not json at all',
      '[]',
      '{"username":"user@example.com"}',
      '{"xcrossSealed":99,"nonce":"","data":""}',
    ]) {
      expect(LocalCipher.isSealed(plain), isFalse, reason: plain);
      await expectLater(
        cipher().open(plain),
        throwsA(isA<LocalCipherError>()),
        reason: plain,
      );
    }
  });

  test('malformed envelopes fail closed', () async {
    for (final bad in [
      '{"xcrossSealed":1}',
      '{"xcrossSealed":1,"nonce":"AAAA","data":"AAAA"}',
      '{"xcrossSealed":1,"nonce":"not base64!","data":"AAAA"}',
    ]) {
      await expectLater(
        cipher().open(bad),
        throwsA(isA<LocalCipherError>()),
        reason: bad,
      );
    }
  });

  test('the key file is created once, owner-only, and reused', () async {
    expect(File(keyPath).existsSync(), isFalse);
    await cipher().seal('a');

    final key = File(keyPath).readAsStringSync();
    expect(base64.decode(key.trim()), hasLength(32));
    if (!Platform.isWindows) {
      expect(FileStat.statSync(keyPath).modeString(), endsWith('rw-------'));
    }

    await cipher().seal('b');
    expect(File(keyPath).readAsStringSync(), key);
  });

  test('a corrupt key file fails loudly instead of using a weak key', () async {
    File(keyPath).writeAsStringSync('not-base64-at-all!!');
    await expectLater(cipher().seal('a'), throwsA(isA<LocalCipherError>()));
  });

  test('a hostless machine id falls back to key-only binding', () async {
    final sealed = await cipher(machineId: '').seal('secret');

    expect(jsonDecode(sealed), containsPair('bind', 'key-only'));
    expect(await cipher(machineId: '').open(sealed), 'secret');
  });

  test('machine binding is recorded in the envelope', () async {
    expect(
      jsonDecode(await cipher().seal('secret')),
      containsPair('bind', 'machine'),
    );
  });

  // The regression this guards: if the binding were re-detected at open
  // time instead of read from the envelope, a machine-id lookup that
  // stopped working would silently derive a key-only key and the session
  // would be lost rather than reported.
  test('a key-only envelope opens without any machine id', () async {
    final sealed = await cipher(machineId: '').seal('secret');
    expect(await cipher(machineId: 'machine-b').open(sealed), 'secret');
    expect(await cipher(machineId: 'machine-c').open(sealed), 'secret');
  });

  test('a machine envelope reports a machine id that vanished', () async {
    final sealed = await cipher().seal('secret');

    await expectLater(
      cipher(machineId: '').open(sealed),
      throwsA(
        isA<LocalCipherError>().having(
          (e) => e.message,
          'message',
          contains('no longer readable'),
        ),
      ),
    );
  });

  test('an unknown binding is refused rather than guessed', () async {
    final doc =
        jsonDecode(await cipher().seal('secret')) as Map<String, Object?>;
    doc['bind'] = 'something-else';

    await expectLater(
      cipher().open(jsonEncode(doc)),
      throwsA(isA<LocalCipherError>()),
    );
  });
}
