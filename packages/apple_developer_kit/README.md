# apple_developer_kit

Apple Developer tooling for Dart: GrandSlam / Anisette login, App Store Connect
provisioning, in-process codesigning, and the ADI (Provision) client.

Used by [xcross](https://github.com/arxdeus/xcross) to authenticate, provision
development identities, and sign iOS `.app` bundles on Linux and Windows
without Xcode.

## Install

```sh
dart pub add apple_developer_kit
```

## Features

- **ADI + Anisette** — load Apple Music ADI native libs, provision the machine,
  emit `X-Apple-I-MD*` headers
- **GrandSlam** — Apple ID SRP login (with optional 2FA) and Developer Services
  app-token exchange
- **App Store Connect** — Team API-key client to issue development certs,
  register devices/bundle IDs, and create `IOS_APP_DEVELOPMENT` profiles
- **Codesign** — in-process Mach-O / `.app` signing from PEM key + cert +
  provisioning profile (layout constrained to what xcross packs)

## Usage

These illustrative functions take caller-selected host services and native loader.
Choose the explicit Linux, macOS, or Windows composition functions in
`composition/apple_host.dart` and `composition/native_library_loader.dart`
for the intended host. Client factories must return fresh HTTP clients, which
these functions close. A supplied `AnisetteProvider` remains caller-owned.

### Fetch ADI libraries and produce Anisette headers

```dart
import 'package:apple_developer_kit/host/shared/adi/loader/loader.dart';
import 'package:apple_developer_kit/host/shared/apple_host_services.dart';
import 'package:apple_developer_kit/shared/adi/apk_fetch.dart';
import 'package:apple_developer_kit/shared/grandslam/anisette/anisette_data_provider.dart';
import 'package:http/http.dart' as http;

Future<Map<String, String>> anisetteHeaders({
  required AppleHostServices hostServices,
  required NativeLibraryLoader loader,
  required String cacheDir,
  required http.Client Function() createClient,
}) async {
  final libs = AdiLibraryFetcher(
    cacheDir: cacheDir,
    hostServices: hostServices,
    abi: hostServices.abi,
    createClient: createClient,
  );
  await libs.ensureLibraries();
  final anisette = AnisetteDataProvider(
    cacheDir,
    hostServices: hostServices,
    loader: loader,
    httpClient: createClient(),
  );
  try {
    return await anisette.fetchAnisetteHeaders();
  } finally {
    anisette.close();
  }
}
```

### Apple ID (GrandSlam) login

```dart
import 'package:apple_developer_kit/shared/grandslam/anisette/anisette_provider.dart';
import 'package:apple_developer_kit/shared/grandslam/grandslam_login.dart';
import 'package:apple_developer_kit/shared/grandslam/grandslam_login_data.dart';
import 'package:apple_developer_kit/shared/grandslam/grandslam_two_factor.dart';
import 'package:http/http.dart' as http;

Future<GrandSlamLoginData> login({
  required AnisetteProvider anisette,
  required http.Client Function() createClient,
  required String username,
  required String password,
  required FetchTwoFactorCode fetchTwoFactorCode,
}) async {
  final client = GrandSlamClient(
    endpoints: await anisette.resolveGrandSlamEndpoints(),
    fetchAnisetteHeaders: anisette.fetchAnisetteHeaders,
    httpClient: createClient(),
  );
  try {
    return await client.login(
      username: username,
      password: password,
      fetchTwoFactorCode: fetchTwoFactorCode,
    );
  } finally {
    client.close();
  }
}
```

Supply a 2FA callback that prompts for the requested mode and returns null to
cancel. Keep credentials and returned login data out of logs.

### Troubleshooting Apple ID login

- **HTTP 503 and Xcode client-info:** Apple's GrandSlam edge rejects
  `X-MMe-Client-Info` containing `com.apple.dt.Xcode`, as documented in
  [anisette-v3-server #59](https://github.com/Dadoum/anisette-v3-server/issues/59).
  The built-in provider and GSA requests use `com.apple.akd/1.0`. Custom providers
  must supply compatible client-info too. The Developer Services app identifier
  `com.apple.gs.xcode.auth` is a separate value and must not be replaced.
- **HTTP 429 at `o=complete` after switching to `akd`:** this can be a
  connection-reuse problem, not necessarily an account/IP cooldown.
  [iLoader #709](https://github.com/nab138/iloader/issues/709) reports the same
  proof-request failure. Its [v2.3.3 release](https://github.com/nab138/iloader/releases/tag/v2.3.3)
  disabled connection pooling via
  [isideload f6a4d5d](https://github.com/nab138/isideload/commit/f6a4d5dba717d72fc2af63eaba26b27ba44116be).
  xcross applies the equivalent policy with `persistentConnection = false` on
  every GrandSlam request, including lookup, provisioning, SRP, and 2FA. TLS
  certificate verification remains enabled. No failed proof is automatically
  replayed and no Anisette identity is reset.
- **Other/persistent HTTP 429:** GrandSlam and Developer Services report
  `AppleRateLimitError` with the failing operation and
  a parsed `retryAfter` duration when Apple provides one (seconds or HTTP date).
  Requests are not automatically replayed. Wait at least the stated duration.
  If Apple provides no usable duration, stop repeated attempts and try later.
  Changing client-info does not remove an existing server-side cooldown.
- Do not run `xcross auth clean`, delete ADI/Anisette state, or reset your password
  to address a 429. Keep the existing machine identity and saved session. If it
  persists, report the failing operation and HTTP status, not passwords, tokens,
  Anisette headers, or session files.

The connection policy has an opt-in live transport check. From this package
directory, set `XCROSS_LIVE_GSA_TRANSPORT=1` and run
`dart test test/grandslam/anisette/grandslam_transport_live_test.dart`.
It sends two endpoint-lookup GETs to Apple using the production client and
checks that they open two connections. It does not load credentials, ADI, or
saved state, and does not prove that a particular account can sign in.

### App Store Connect development provisioning

```dart
import 'package:apple_developer_kit/host/shared/apple_host_services.dart';
import 'package:apple_developer_kit/shared/appstoreconnect/appstoreconnect.dart';
import 'package:apple_developer_kit/shared/appstoreconnect/asc_client.dart';
import 'package:apple_developer_kit/shared/appstoreconnect/asc_config.dart';
import 'package:http/http.dart' as http;

Future<DevelopmentIdentityPaths> provision({
  required AppleHostServices hostServices,
  required http.Client Function() createClient,
  required String issuerId,
  required String keyId,
  required String privateKeyPath,
  required String bundleId,
  required List<String> deviceUdids,
  required String outputDir,
}) async {
  final credentials = AscCredentials(
    hostServices: hostServices,
    issuerId: issuerId,
    keyId: keyId,
    privateKeyPath: privateKeyPath,
  );
  final asc = AscClient(credentials, httpClient: createClient());
  try {
    return await AscProvisioning(hostServices: hostServices, client: asc)
        .provisionDevelopmentIdentity(
      bundleId: bundleId,
      deviceUdids: deviceUdids,
      outputDir: outputDir,
    );
  } finally {
    asc.close();
  }
}
```

### Sign an `.app` bundle

```dart
import 'package:apple_developer_kit/host/shared/apple_host_services.dart';
import 'package:apple_developer_kit/shared/appstoreconnect/appstoreconnect.dart';
import 'package:apple_developer_kit/shared/signing/bundle_signer.dart';
import 'package:apple_developer_kit/shared/signing/signing_asset.dart';

Future<void> signApp(
  AppleHostServices hostServices,
  DevelopmentIdentityPaths paths,
  String appPath,
) async {
  final asset = await SigningAssetLoader(hostServices: hostServices).load(
    privateKeyPemPath: paths.privateKeyPemPath,
    certificatePemPath: paths.certificatePemPath,
    provisioningProfilePath: paths.profilePath,
  );
  await BundleSigner(asset, hostServices: hostServices).signApp(appPath);
}
```

## Scope / limits

- ADI libraries are downloaded on demand from the Apple Music APK; they are
  **not** redistributed with this package.
- `BundleSigner` targets the constrained `.app` layout xcross produces
  (nested `.framework` / dylibs). Watch / PlugIns / Extensions are rejected.
- Prefer App Store Connect API keys for CI; GrandSlam is for interactive
  Apple ID sessions.

## License / attribution

ADI-related code is derived from
[Dadoum/Provision](https://github.com/Dadoum/Provision) (LGPLv2). See
`NOTICE.md` and `ADI_LICENSE`. See `LICENSE` for the package license text.

## Related

Part of the [xcross](https://github.com/arxdeus/xcross) monorepo.
