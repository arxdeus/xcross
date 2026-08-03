@TestOn('linux')
library;

import 'dart:io';

import 'package:apple_developer_kit/apple_developer_kit.dart';
import 'package:test/test.dart';

void main() {
  // NOTE: this test downloads the real Apple Music APK (Apple's own
  // native libraries; not redistributed with this package for licensing
  // reasons — see NOTICE.md) on first run, and caches it under
  // ~/.cache/provision_dart. It is network-dependent and will fail/be
  // slow in offline CI sandboxes; that's expected for this phase.
  //
  // It does NOT exercise real Apple provisioning (no network calls to
  // Apple's GrandSlam servers) — it only proves the download/extract/
  // custom-ELF-load/relocate/symbol-lookup plumbing isn't broken. It does
  // NOT run under ASan/valgrind and has not been used to validate the
  // manual relocation logic against memory-safety tooling — see
  // NOTICE.md; that remains required before this is trusted with real
  // Apple ID credentials.
  //
  // Linux: PosixNativeLibraryLoader. Windows: covered by
  // adi_client_windows_test.dart.
  test(
    'native ADI library can be fetched, manually ELF-loaded, and a known symbol resolved',
    () async {
      final fetcher = AdiLibraryFetcher();
      final (coreAdiPath, storeServicesPath, apkSha256) = await fetcher
          .ensureLibraries();

      expect(File(coreAdiPath).existsSync(), isTrue);
      expect(File(storeServicesPath).existsSync(), isTrue);
      expect(apkSha256, isNotEmpty);

      // Full custom-loader + binding + client construction: this
      // manually ELF-loads libstoreservicescore.so, applies relocations
      // (exercising the dlopen-emulation path too, if
      // libstoreservicescore.so pulls in libCoreADI.so lazily at
      // load/relocation time — see AdiClient.fromDirectory's doc
      // comment), and resolves all 11 ADI symbols in AdiNativeBindings'
      // constructor. Any failure in that chain throws before `client` is
      // ever produced — still without making any real provisioning
      // network calls.
      final client = AdiClient.fromDirectory(fetcher.cacheDir.path);
      expect(client, isNotNull);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
