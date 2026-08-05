# darwin_sdk_kit

Resolve and install Darwin/iOS SDK artifact bundles (from `Xcode.xip`) and find
a usable `ld64.lld` on Linux and Windows.

Used by [xcross](https://github.com/arxdeus/xcross) to build iOS apps without
installing Xcode or macOS. The Xcode archive is SDK input only — do not
redistribute extracted Apple SDK contents.

## Install

```sh
dart pub add darwin_sdk_kit
```

## Usage

```dart
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';

// Resolve the SDK installed under the xcross config dir, or null if missing.
final sdk = DarwinSdk.current();
if (sdk == null) {
  throw StateError('Run: xcross sdk install <Xcode.xip>');
}

final iphoneOsSdk = sdk.iPhoneOSSdk();
final linker = await DarwinSdk.resolveLd64Lld(sdk);

// Low-level: stream decoded CPIO entries from an Xcode.xip.
await for (final entry in XcodeXipExtractor.extract('/path/to/Xcode.xip')) {
  // Filter / write entries as needed…
}
```

## Scope

- **`DarwinSdk`** — locate a valid `xcross-darwin.artifactbundle`, pick an
  iPhoneOS SDK, resolve stock LLVM `ld64.lld` (skips swiftly proxy shims).
- **`XcodeXipExtractor`** — pure-Dart XAR → pbzx → CPIO decode of `Xcode.xip`.
- **`XarReader` / `PbzxReader` / `CpioReader`** — format primitives used by the
  extractor.

Default install location: `~/.config/xcross/swift-sdks/…` (or
`%APPDATA%\xcross\swift-sdks\…` on Windows).

## Related

Part of the [xcross](https://github.com/arxdeus/xcross) monorepo. Depends on
[`cli_kit`](https://github.com/arxdeus/xcross/tree/main/packages/cli_kit).
