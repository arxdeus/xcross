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
