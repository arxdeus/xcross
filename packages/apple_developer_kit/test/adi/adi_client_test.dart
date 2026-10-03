@TestOn('linux || mac-os')
library;

import 'dart:io';

import 'package:apple_developer_kit/apple_developer_kit.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import '../support/host_services.dart';

void main() {
  test(
    'real ADI initializes and queries isolated unprovisioned state',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'adi-native-smoke-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final apk = Platform.environment['ADI_TEST_APK'];
      if (apk != null) File(apk).copySync('${directory.path}/applemusic.apk');
      final fetcher = AdiLibraryFetcher(
        cacheDir: directory,
        abi: testHostServices.abi,
        createClient: http.Client.new,
      );
      final paths = await fetcher.ensureLibraries();
      expect(File(paths.coreAdiPath).existsSync(), isTrue);
      expect(File(paths.storeServicesPath).existsSync(), isTrue);
      expect(paths.apkSha256, hasLength(64));
      final client = AdiClient.fromDirectory(
        fetcher.libraryDirectory.path,
        loader: testNativeLoader(),
      );
      final state = Directory('${directory.path}/state')..createSync();
      client.provisioningPath = state.path;
      client.identifier = '0123456789abcdef';
      expect(await client.isMachineProvisioned(-2), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 5)),
    skip: Platform.environment['ADI_NATIVE_SMOKE'] != '1'
        ? 'Set ADI_NATIVE_SMOKE=1 for isolated real Apple APK validation.'
        : false,
  );
}
