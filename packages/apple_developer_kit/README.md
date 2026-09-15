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

### Fetch ADI libraries and produce Anisette headers

```dart
import 'package:apple_developer_kit/apple_developer_kit.dart';

final libs = AdiLibraryFetcher();
final (coreAdi, storeServices, _) = await libs.ensureLibraries();
// Both .so files land in libs.cacheDir (x86_64 slice from Apple Music APK).

final anisette = AnisetteDataProvider(libs.cacheDir.path);
final headers = await anisette.fetchAnisetteHeaders();
final endpoints = await anisette.resolveGrandSlamEndpoints();
anisette.close();
```

### Apple ID (GrandSlam) login

```dart
final client = GrandSlamClient(
  endpoints: endpoints,
  fetchAnisetteHeaders: anisette.fetchAnisetteHeaders,
);

final login = await client.login(
  username: 'you@example.com',
  password: password,
  fetchTwoFactorCode: (mode) async {
    // Prompt for the 6-digit code (mode is sms / trustedDevice / …).
    // Return null to cancel.
    return code;
  },
);
client.close();
```

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
- Do not run `xcross auth clear`, delete ADI/Anisette state, or reset your password
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
final credentials = AscCredentials(
  issuerId: issuerId,
  keyId: keyId,
  privateKeyPath: '/path/to/AuthKey_<keyId>.p8',
);
// Or: await AscCredentials.fromFile();

final asc = AscClient(credentials);
final paths = await AscProvisioning.provisionDevelopmentIdentity(
  client: asc,
  bundleId: 'com.example.app',
  deviceUdids: [udid],
  outputDir: outputDir,
);
asc.close();
// paths.certificatePemPath / privateKeyPemPath / profilePath
```

### Sign an `.app` bundle

```dart
final asset = await SigningAsset.load(
  privateKeyPemPath: paths.privateKeyPemPath,
  certificatePemPath: paths.certificatePemPath,
  provisioningProfilePath: paths.profilePath,
);

await BundleSigner(asset).signApp('/path/to/Runner.app');
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
