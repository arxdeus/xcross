<div align="center">

# xcross

[![Integration Tests](https://img.shields.io/github/actions/workflow/status/arxdeus/xcross/integration.yml?branch=main&style=flat-square&label=tests)](https://github.com/arxdeus/xcross/actions/workflows/integration.yml)
[![Latest release](https://img.shields.io/github/v/release/arxdeus/xcross?style=flat-square&label=release)](https://github.com/arxdeus/xcross/releases)
[![GitHub stars](https://img.shields.io/github/stars/arxdeus/xcross?style=flat-square&label=stars)](https://github.com/arxdeus/xcross/stargazers)
[![Open issues](https://img.shields.io/github/issues/arxdeus/xcross?style=flat-square)](https://github.com/arxdeus/xcross/issues)
![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20Windows-3C873A?style=flat-square)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square)](https://opensource.org/licenses/MIT)

**Build, run, and hot-reload Flutter iOS apps natively from Linux or Windows.**

[Install](#install) • [Windows](#windows-native) • [Quick start](#quick-start) • [Commands](#commands) • [IDE](#ide) • [FAQ](#faq)

</div>

xcross implements the Flutter iOS build pipeline and the iOS 17+ CoreDevice launch protocol in Dart. It does not require xtool, WSL, macOS, or an installed copy of Xcode.

- 🐧🪟 **Native Linux and Windows** with the official Swift and LLVM toolchains
- 🔥 **Hot reload on iOS 17+** over a `pymobiledevice3` RSD tunnel
- 📦 **Native signing and install** with an Apple ID or App Store Connect API key
- 🔌 **SwiftPM plugins** on both Linux and Windows
- ⚙️ **Direct build pipeline**: `frontend_server` → `clang` → `ld64.lld` → `.app`/`.ipa`

> [!IMPORTANT]
> xcross produces debug/JIT device builds. Release/AOT builds still require Flutter's macOS build tooling. Launching with xcross requires iOS 17 or later.

## Requirements

Both Linux and Windows require:

- [Flutter](https://flutter.dev)
- The official [Swift toolchain](https://www.swift.org/install/)
- Official [LLVM](https://releases.llvm.org/) tools on `PATH`: `clang`, `clang++`, `llvm-ar`, and `ld64.lld`
- Python 3 and `pymobiledevice3`
- A complete `Xcode.xip`, processed once with `xcross sdk install <Xcode.xip>` to create xcross's private Darwin Swift SDK

The Xcode archive is only SDK input; neither Xcode nor macOS is installed or used. Do not redistribute the extracted Apple SDK.

### Linux

Install Flutter and Swift first, then let xcross install the supported apt requirements and `pymobiledevice3`:

```sh
xcross setup
xcross sdk install ~/Downloads/Xcode.xip
```

For USB device access and diagnostics, `xcross setup` installs `usbmuxd`, `usbutils`, and `libimobiledevice-utils`.

Apple ID authentication on Linux uses Android ADI libraries (`libCoreADI.so` and `libstoreservicescore.so`). On x86_64, `xcross auth` downloads them from the Apple Music APK into `~/.config/xcross/adi-libs` on first use. On other architectures, extract the matching APK slice and pass `--adi-library-dir`:

```sh
xcross auth --apple-id you@example.com
```

The command prompts for the password and 2FA code, then stores only the resulting Developer Services session. App Store Connect API-key authentication remains available with `--issuer-id`, `--key-id`, and `--private-key`.

### Windows (native)

Download `xcross-windows-x64.zip` from [Releases](https://github.com/arxdeus/xcross/releases), extract it, and put the `bin` directory on `PATH`. The archive contains `bin/xcross.exe` and `lib/sysv_abi_bridge.dll` (ADI auth native asset). Signing runs in process, so no signing executable is bundled. Swift, LLVM, Flutter, and the Apple SDK are host prerequisites and are not bundled.

Install Swift and LLVM from an Administrator PowerShell:

```powershell
winget install --id Swift.Toolchain --exact
winget install --id LLVM.LLVM --exact
```

Also install Flutter, Python 3, and `pymobiledevice3`:

```powershell
py -m pip install -U pymobiledevice3
xcross setup
xcross sdk install C:\Downloads\Xcode.xip
```

Apple ID authentication uses the same Android ADI libraries as Linux (`libCoreADI.so` and `libstoreservicescore.so`). On x64, `xcross auth` downloads them from the Apple Music APK into `%APPDATA%\xcross\adi-libs` on first use.

```powershell
xcross auth --apple-id you@example.com
```

The command prompts for the password and 2FA code, then stores only the resulting Developer Services session. App Store Connect API-key authentication remains available with `--issuer-id`, `--key-id`, and `--private-key`.

Before each device reconnect, run `xcross prepare` in an Administrator PowerShell. Device launch requires iOS 17+.

## Install

### Linux

```sh
curl -fsSL https://raw.githubusercontent.com/arxdeus/xcross/main/install.sh | sh
```

### Windows

Use the release archive described in [Windows (native)](#windows-native).

## Quick start

### Linux

```sh
xcross setup
xcross sdk install ~/Downloads/Xcode.xip   # once
xcross auth --apple-id you@example.com     # or ASC API key flags
xcross prepare                             # once per device reconnect
cd my_flutter_app
xcross flutter run [-u <UDID>]
xcross ide vscode
```

### Windows

```powershell
# Administrator PowerShell, once per reconnect:
xcross prepare

# Normal terminal:
cd my_flutter_app
xcross flutter run -u <UDID>
```

## Flutter plugins

Swift Package Manager iOS Flutter plugins and packages are supported on Windows exactly as on Linux. Their native code is compiled into `Frameworks/libFlutterPluginsGenerated.dylib` and registered by the generated runner.

Plugins that only provide a CocoaPods podspec are currently omitted with a warning. Use a plugin release that includes `ios/<package_name>/Package.swift` when available.

## Commands

```text
xcross auth             save native Apple ID or App Store Connect credentials
xcross sdk install      extract a Darwin Swift SDK from Xcode.xip
xcross prepare          mount DDI + start the iOS 17+ RSD tunnel
xcross flutter build    build a debug .app (or .ipa with -i)
xcross flutter run      build → sign → install → launch → hot reload
xcross ide vscode       upsert .vscode/* for Run & Debug / Hot Reload
xcross ide idea         write a JetBrains DAP run config (needs LSP4IJ)
xcross completion       print a shell-completion script
```

`xcross flutter build` writes apps to `build/xcross-ios/<appName>.app`.

**`xcross flutter build`**

```text
-t, --target <path>          lib/main.dart
-D, --dart-define k=v        repeatable
    --dart-define-from-file  .json / .env, repeatable
    --[no-]pub               flutter pub get first (default: on)
    --build-name / --build-number
    --flavor
-i, --ipa                    .ipa instead of .app
```

**`xcross flutter run`** shares the build options and adds:

```text
-d, --device-id     device id or name
-u, --udid          device UDID; wins if both selectors are set
    --usb / --wifi / --device-connection attached|wireless|both
    --route
-a, --dart-entrypoint-args
-v, --verbose
```

`r` reload · `R` restart · `q` / Ctrl-C / Ctrl-D quit. Multiple devices show a numbered picker in an interactive terminal; pass `-u` for CI or piped runs.

## Bundle identity

Bundle id is read from the Flutter iOS project (same sources as Flutter tooling on non-macOS):

1. Literal `CFBundleIdentifier` in `ios/Runner/Info.plist` (no `$(…)` variables)
2. Otherwise the first `PRODUCT_BUNDLE_IDENTIFIER` in `ios/Runner.xcodeproj/project.pbxproj`

`Info.plist` for the packed `.app` is always taken from `ios/Runner/Info.plist` when present.

## IDE

### VS Code

```sh
xcross ide vscode
```

Writes the DAP shim and upserts the xcross launch entry + DAP settings into `.vscode/`. Press F5 to build, sign, install, and launch; Hot Reload and Restart drive the same `r`/`R` commands as the CLI, and DevTools uses the same VM Service connection.

- Works in VS Code forks with the Dart-Code extension installed.
- The xcross launch config sets `"xcross": true`. Other Flutter configs in the same workspace still work — sessions without that flag are handed to Flutter's own debug adapter.
- For multiple iPhones, set `"args": ["--udid", "<UDID>"]` on the xcross entry; re-running the command preserves those args.
- Existing `launch.json` / `settings.json` are merged in place (xcross keys upserted; other configs and settings kept). A second run is a no-op when already current.
- Run the installed `xcross`; the generated DAP shim records that binary's path.

### JetBrains IDEA / Android Studio

```sh
xcross ide idea
```

Writes `.run/xcross_ios_device.run.xml` — a shared [LSP4IJ](https://plugins.jetbrains.com/plugin/18229-lsp4ij) Debug Adapter Protocol run configuration that starts `xcross flutter dap` over stdio.

- Install the LSP4IJ plugin, then Debug **xcross: iOS device** (do not use Flutter's Run button — it still calls `flutter run`).
- Breakpoints and stepping use the DAP/VM Service path; Restart maps to hot restart. Console `r`/`R` still work.
- Existing `.run/xcross_ios_device.run.xml` is not overwritten.
- Run the installed `xcross`; the run config records that binary's path.

## FAQ

<details>
<summary>Why can't it build release/AOT?</summary>

Dart does not cross-compile an iOS AOT executable. That step still needs Flutter's macOS toolchain.
</details>

<details>
<summary>Does it support the simulator?</summary>

No. xcross builds arm64 device apps with a minimum deployment target of iOS 13; its launch pipeline requires iOS 17+.
</details>

<details>
<summary>What does <code>xcross prepare</code> do?</summary>

It mounts the Developer Disk Image and starts the `pymobiledevice3` RSD tunnel. It needs root on Linux or an Administrator PowerShell on Windows.
</details>

<details>
<summary>Does it support Compose Multiplatform?</summary>

Not yet. xcross currently builds Flutter applications.
</details>

## How it works

```text
flutter build → FlutterPacker
  ├─ FlutterDebugBundler   frontend_server → App.framework
  ├─ SwiftPM plugins       swift build → libFlutterPluginsGenerated.dylib
  ├─ RunnerShim            clang / ld64.lld → Runner
  └─ Info.plist

flutter run → build → native sign/install → iOS 17+ CoreDevice launch
```

The build resolves Flutter, runs `flutter pub get`, fetches the iOS engine artifacts, builds the JIT kernel, compiles SwiftPM plugins, links the runner, and assembles `build/xcross-ios/<appName>.app`. Passing `-i/--ipa` packages the same app as an IPA.
