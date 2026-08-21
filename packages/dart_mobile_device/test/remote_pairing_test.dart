import 'dart:io';

import 'package:dart_mobile_device/src/pymd/remote_pairing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('RemotePairing pairing records', () {
    late Directory home;

    setUp(() {
      home = Directory.systemTemp.createTempSync('xcross_pairing_test');
      RemotePairing.homeOverride = home.path;
    });

    tearDown(() {
      RemotePairing.homeOverride = null;
      home.deleteSync(recursive: true);
    });

    void writeRecord(String id) =>
        File(p.join(home.path, 'remote_$id.plist')).writeAsStringSync('');

    test('no directory → no records, pairing offered', () {
      RemotePairing.homeOverride = p.join(home.path, 'does-not-exist');
      expect(RemotePairing.pairingRecordIds(), isEmpty);
      expect(RemotePairing.shouldOfferPairing(), isTrue);
    });

    test('empty directory → pairing offered', () {
      expect(RemotePairing.pairingRecordIds(), isEmpty);
      expect(RemotePairing.shouldOfferPairing(), isTrue);
    });

    test('parses the UDID out of remote_<UDID>.plist', () {
      writeRecord('00008030-000664292232802E');
      expect(RemotePairing.pairingRecordIds(), ['00008030-000664292232802E']);
    });

    test('ignores unrelated files', () {
      File(p.join(home.path, 'other.plist')).writeAsStringSync('');
      Directory(p.join(home.path, 'remote_dir')).createSync();
      expect(RemotePairing.pairingRecordIds(), isEmpty);
    });

    test('any record suppresses pairing for a null selector', () {
      writeRecord('00008030-000664292232802E');
      expect(RemotePairing.shouldOfferPairing(), isFalse);
    });

    test('any record suppresses pairing for a name selector', () {
      writeRecord('00008030-000664292232802E');
      expect(RemotePairing.shouldOfferPairing('iPhone Mind'), isFalse);
    });

    test('matching UDID selector suppresses pairing, dashes ignored', () {
      writeRecord('00008030-000664292232802E');
      expect(
        RemotePairing.shouldOfferPairing('00008030000664292232802E'),
        isFalse,
      );
    });

    test('non-matching UDID selector still offers pairing', () {
      writeRecord('00008030-000664292232802E');
      expect(
        RemotePairing.shouldOfferPairing('00008110-001122334455667E'),
        isTrue,
      );
    });
  });

  group('RemotePairing.looksLikeUdid', () {
    test('accepts modern and legacy UDIDs', () {
      expect(RemotePairing.looksLikeUdid('00008030-000664292232802E'), isTrue);
      expect(
        // 40-hex legacy UDID.
        RemotePairing.looksLikeUdid('0123456789abcdef0123456789abcdef01234567'),
        isTrue,
      );
    });

    test('rejects device names', () {
      expect(RemotePairing.looksLikeUdid('iPhone Mind'), isFalse);
      expect(RemotePairing.looksLikeUdid('fresh-box-1'), isFalse);
    });
  });
}
