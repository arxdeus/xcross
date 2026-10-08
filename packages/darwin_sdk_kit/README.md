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

Pass a repository, toolchain resolver and extractor composed for the same
selected host. `DarwinSdkRepository(host, log: log)` owns SDK resolution,
`DarwinToolchainResolver(runner, locations)` uses host-specific tool locations,
and `XcodeXipExtractor(host)` streams archive entries. Filtering and writing
entries remains the caller's responsibility.

```dart
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:darwin_sdk_kit/shared/archive/xcode_xip_extractor.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk_repository.dart';
import 'package:darwin_sdk_kit/shared/toolchain/darwin_toolchain_resolver.dart';

Future<void> inspectSdk<T extends PlatformHostInterface>(
  DarwinSdkRepository<T> repository,
  DarwinToolchainResolver<T> toolchain,
  XcodeXipExtractor<T> extractor,
  String xipPath,
) async {
  final sdk = repository.current();
  if (sdk == null) {
    throw StateError('Run: xcross sdk install <Xcode.xip>');
  }
  final linker = await toolchain.resolveLd64Lld();
  print('SDK: ${sdk.swiftSdkPath}, linker: $linker');
  await for (final entry in extractor.extract(xipPath)) {
    print(entry);
  }
}
```

## Scope

- **`DarwinSdk` / `DarwinSdkRepository`**: describe and locate a valid
  `xcross-darwin.artifactbundle`.
- **`DarwinToolchainResolver`**: resolve stock LLVM `ld64.lld` using selected
  host locations (skips swiftly proxy shims).
- **`XcodeXipExtractor`** — pure-Dart XAR → pbzx → CPIO decode of `Xcode.xip`.
- **`CpioReader` / `CpioEntry`**: public CPIO primitives. XAR and pbzx
  implementation details remain internal to the extractor.

Default install location: `~/.config/xcross/swift-sdks/…` (or
`%APPDATA%\xcross\swift-sdks\…` on Windows).

## Related

Part of the [xcross](https://github.com/arxdeus/xcross) monorepo. Depends on
[`cli_kit`](https://github.com/arxdeus/xcross/tree/main/packages/cli_kit).
