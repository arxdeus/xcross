@TestOn('windows')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:apple_developer_kit/shared/adi/apk_fetch.dart';
import 'package:apple_developer_kit/src/shared/adi/adi_client.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import '../support/host_services.dart';

void main() {
  // Downloads the real Apple Music APK on first run (not redistributed;
  // see NOTICE.md). Proves Windows VirtualAlloc ELF load + SysV bridge +
  // ADI symbol resolution. Does not call Apple provisioning endpoints.
  test(
    'native ADI library can be fetched, ELF-loaded on Windows, and symbols resolved',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'adi-windows-smoke-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final fetcher = AdiLibraryFetcher(
        hostServices: testHostServices,
        cacheDir: directory.path,
        abi: testHostServices.abi,
        createClient: http.Client.new,
      );
      final paths = await fetcher.ensureLibraries();

      expect(File(paths.coreAdiPath).existsSync(), isTrue);
      expect(File(paths.storeServicesPath).existsSync(), isTrue);
      expect(paths.apkSha256, isNotEmpty);

      final client = AdiClient.fromDirectory(
        fetcher.libraryDirectory.path,
        loader: testNativeLoader(),
      );
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
    // The SysV bridge and the loaded code are both x86_64.
    skip: Platform.environment['ADI_NATIVE_SMOKE'] != '1'
        ? 'Set ADI_NATIVE_SMOKE=1 for isolated real Apple APK validation.'
        : Abi.current() == Abi.windowsX64
        ? null
        : 'ADI is x86_64-only (host is ${Abi.current()}).',
  );
}
