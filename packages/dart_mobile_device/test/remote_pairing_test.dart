import 'dart:io';

import 'package:cli_kit/host/macos/macos_host.dart';
import 'package:cli_kit/host/shared/posix_privileges.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:dart_mobile_device/host/macos/macos_device_host.dart';
import 'package:dart_mobile_device/src/target/iphone/device/pymd/remote_pairing.dart';
import 'package:dart_mobile_device/target/iphone/device/pymd/pymd.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'test_log_output.dart';

void main() {
  final runner = ProcessRunner(
    stdinStream: const Stream.empty(),
    stdoutSink: testSink(),
    stderrSink: testSink(),
    MacOSHost(),
    log: testLog(),
  );
  var pairing = RemotePairing(
    Pymd(
      console: TestDeviceConsole(),
      localHttp: testLocalHttp(),
      runner,
      privileges: PosixPrivileges(runner),
      hostPolicy: MacOSDeviceHost(runner),
    ),
  );
  group('RemotePairing pairing records', () {
    late Directory home;

    setUp(() {
      home = Directory.systemTemp.createTempSync('xcross_pairing_test');
      pairing = RemotePairing(
        Pymd(
          console: TestDeviceConsole(),
          localHttp: testLocalHttp(),
          runner,
          privileges: PosixPrivileges(runner),
          hostPolicy: MacOSDeviceHost(runner),
          pairingHome: home.path,
        ),
      );
    });

    tearDown(() {
      home.deleteSync(recursive: true);
    });

    void writeRecord(String id) =>
        File(p.join(home.path, 'remote_$id.plist')).writeAsStringSync('');

    test('no directory → no records, pairing offered', () {
      pairing = RemotePairing(
        Pymd(
          console: TestDeviceConsole(),
          localHttp: testLocalHttp(),
          runner,
          privileges: PosixPrivileges(runner),
          hostPolicy: MacOSDeviceHost(runner),
          pairingHome: p.join(home.path, 'does-not-exist'),
        ),
      );
      expect(pairing.pairingRecordIds(), isEmpty);
      expect(pairing.shouldOfferPairing(), isTrue);
    });

    test('empty directory → pairing offered', () {
      expect(pairing.pairingRecordIds(), isEmpty);
      expect(pairing.shouldOfferPairing(), isTrue);
    });

    test('parses the UDID out of remote_<UDID>.plist', () {
      writeRecord('00008030-000664292232802E');
      expect(pairing.pairingRecordIds(), ['00008030-000664292232802E']);
    });

    test('ignores unrelated files', () {
      File(p.join(home.path, 'other.plist')).writeAsStringSync('');
      Directory(p.join(home.path, 'remote_dir')).createSync();
      expect(pairing.pairingRecordIds(), isEmpty);
    });

    test('any record suppresses pairing for a null selector', () {
      writeRecord('00008030-000664292232802E');
      expect(pairing.shouldOfferPairing(), isFalse);
    });

    test('any record suppresses pairing for a name selector', () {
      writeRecord('00008030-000664292232802E');
      expect(pairing.shouldOfferPairing('iPhone Mind'), isFalse);
    });

    test('matching UDID selector suppresses pairing, dashes ignored', () {
      writeRecord('00008030-000664292232802E');
      expect(pairing.shouldOfferPairing('00008030000664292232802E'), isFalse);
    });

    test('non-matching UDID selector still offers pairing', () {
      writeRecord('00008030-000664292232802E');
      expect(pairing.shouldOfferPairing('00008110-001122334455667E'), isTrue);
    });
  });

  group('pairing.advertiseName', () {
    test('is xcross- prefixed exactly once', () {
      expect(pairing.advertiseName, startsWith('xcross-'));
      expect(pairing.advertiseName, isNot(startsWith('xcross-xcross-')));
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
