# open_apple_macros

Builds an open-source Swift compiler plugin server that implements Apple's
closed-source macro modules (`SwiftUIMacros`, `PreviewsMacros`,
`FoundationModelsMacros`) so iOS sources using `@State`, `@Entry`,
`@Animatable`, `#Preview`, `@Generable` and friends compile with any host
Swift toolchain on macOS, Linux and Windows.

The Swift sources are adapted from
[OpenAppleMacros](https://github.com/xtool-org/OpenAppleMacros); see
`NOTICE.md`.

## Usage

```dart
import 'package:cli_kit/shared/process/process.dart';
import 'package:open_apple_macros/host/shared/posix_toolchain_plugin_layout.dart';
import 'package:open_apple_macros/shared/open_apple_macros_server.dart';

Future<List<String>> macroArguments(ProcessRunner runner) async {
  final server = OpenAppleMacrosServer(
    runner: runner,
    layout: const PosixToolchainPluginLayout(),
  );
  final build = await server.ensure(
    cacheRoot: '/path/to/cache',
    swiftDriver: const SwiftToolCommand('swiftc'),
    swiftBuild: const SwiftToolCommand('swift', ['build']),
  );
  return build.swiftBuildArguments;
}
```

Use `WindowsToolchainPluginLayout` and `SwiftToolCommand('swift-build')` on
Windows. Pass `swiftBuildArguments` to `swift build`. They put the host
toolchain plugin directory first, so the open-source `SwiftMacros`,
`ObservationMacros` and `FoundationMacros` plugins win over any Apple
plugins shipped in a Swift SDK, then register the server for the
Apple-only modules.

The server is built once per source revision, toolchain and host in a
debug configuration under `<cacheRoot>/open-apple-macros/` and reused
afterwards.

## Related

Part of the [xcross](https://github.com/arxdeus/xcross) monorepo.
