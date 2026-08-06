@TestOn('windows')
library;

import 'dart:io';

import 'package:apple_developer_kit/apple_developer_kit.dart';
import 'package:test/test.dart';

void main() {
  // Downloads the real Apple Music APK on first run (not redistributed;
  // see NOTICE.md). Proves Windows VirtualAlloc ELF load + SysV bridge +
  // ADI symbol resolution. Does not call Apple provisioning endpoints.
  test(
    'native ADI library can be fetched, ELF-loaded on Windows, and symbols resolved',
    () async {
      final fetcher = AdiLibraryFetcher();
      final paths = await fetcher.ensureLibraries();

      expect(File(paths.coreAdiPath).existsSync(), isTrue);
      expect(File(paths.storeServicesPath).existsSync(), isTrue);
      expect(paths.apkSha256, isNotEmpty);

      final client = AdiClient.fromDirectory(fetcher.cacheDir.path);
      expect(client, isNotNull);
      // First real ADI calls (hits SysV import trampolines). A bad bridge
      // used to kill the process here with no Dart exception.
      client.provisioningPath =
          '${Directory.systemTemp.createTempSync('adi-prov').path.replaceAll(r'\', '/')}/';
      client.identifier = '0123456789abcdef';
      // -2 is the conventional "DSID unknown / not provisioned" probe.
      final provisioned = await client.isMachineProvisioned(-2);
      expect(provisioned, isA<bool>());
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
