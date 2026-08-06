<div align="center">

# xcross

[![Integration Tests](https://img.shields.io/github/actions/workflow/status/arxdeus/xcross/integration.yml?branch=main&style=flat-square&label=tests)](https://github.com/arxdeus/xcross/actions/workflows/integration.yml)
[![Latest release](https://img.shields.io/github/v/release/arxdeus/xcross?style=flat-square&label=release)](https://github.com/arxdeus/xcross/releases)
[![GitHub stars](https://img.shields.io/github/stars/arxdeus/xcross?style=flat-square&label=stars)](https://github.com/arxdeus/xcross/stargazers)
[![Open issues](https://img.shields.io/github/issues/arxdeus/xcross?style=flat-square)](https://github.com/arxdeus/xcross/issues)
![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20Linux-3C873A?style=flat-square)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square)](https://opensource.org/licenses/MIT)

**Build, run, and hot-reload Flutter iOS apps natively from Windows or Linux.**

No Mac. No Xcode. No WSL.

[Install](#-installation) • [Quick start](#-quick-start) • [Commands](#-command-reference) • [IDE](#-ide-integration) • [FAQ](#-faq) • [Under the hood](#-under-the-hood)

</div>

---

xcross reimplements the Flutter iOS build pipeline and the iOS 17+ CoreDevice launch protocol in pure Dart. It compiles your Flutter app with the official Swift and LLVM toolchains, signs it with your Apple ID or an App Store Connect API key, installs it on a physical iPhone, launches it, and gives you full hot reload — all from a Windows or Linux machine.

## ✨ Highlights

| | Feature | Details |
|---|---|---|
| 🪟🐧 | **Native Windows & Linux** | Runs directly on the host with official Swift and LLVM toolchains — no VM, no WSL, no macOS anywhere |
| 🔥 | **Hot reload & hot restart** | Full `r` / `R` workflow on a real iPhone over an iOS 17+ RSD tunnel |
| 📦 | **Native signing & install** | Apple ID (free account works) or App Store Connect API key; signing runs in-process |
| 🔌 | **SwiftPM plugins** | Swift Package Manager iOS plugins compile on both Windows and Linux |
| 🧠 | **IDE debugging** | One command sets up VS Code (F5, breakpoints, DevTools) or JetBrains IDEs via DAP |
| ⚙️ | **Direct build pipeline** | `frontend_server` → `clang` → `ld64.lld` → `.app` / `.ipa` — no Xcode build system involved |

> [!IMPORTANT]
> xcross produces **debug (JIT) device builds**. Release/AOT builds still require Flutter's macOS build tooling. Launching with xcross requires **iOS 17 or later** on the device.

## 📋 Requirements

Both platforms need the same five ingredients:

| Requirement | Purpose |
|---|---|
| [Flutter](https://flutter.dev) | Your app's SDK; xcross reuses its engine artifacts |
| [Swift toolchain](https://www.swift.org/install/) | Compiles SwiftPM plugins and runner glue code |
| [LLVM](https://releases.llvm.org/) (`clang`, `clang++`, `llvm-ar`, `ld64.lld` on `PATH`) | Compiles and links the iOS Mach-O binaries |
| Python 3 + [`pymobiledevice3`](https://github.com/doronz88/pymobiledevice3) | Device communication and the iOS 17+ RSD tunnel |
| A complete `Xcode.xip` | Processed **once** by `xcross sdk install` into a private Darwin Swift SDK |

> [!NOTE]
> The Xcode archive is only used as SDK *input* — neither Xcode nor macOS is ever installed or executed. xcross extracts the iOS SDK and frameworks from the archive with its own pure-Dart xar/pbzx/cpio readers. Do not redistribute the extracted Apple SDK.

## 📥 Installation

Both installers download the latest release, install it, **add xcross to your `PATH`**, verify the binary, and print any missing prerequisites with install hints.

### Windows (native)

1. One-line install (PowerShell):

   ```powershell
   irm https://raw.githubusercontent.com/arxdeus/xcross/main/install.ps1 | iex
   ```

2. Install Swift and LLVM from an **Administrator** PowerShell (the installer tells you if they're missing):

   ```powershell
   winget install --id Swift.Toolchain --exact
   winget install --id LLVM.LLVM --exact
   ```

3. Install Flutter, Python 3, and `pymobiledevice3`, then finish setup:

   ```powershell
   py -m pip install -U pymobiledevice3
   xcross setup
   xcross sdk install C:\Downloads\Xcode.xip   # once, takes a while
   ```

### Linux

1. One-line install:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/arxdeus/xcross/main/install.sh | sh
   ```

2. Let xcross install its apt dependencies and `pymobiledevice3`, and build the Darwin SDK:

   ```sh
   xcross setup
   xcross sdk install ~/Downloads/Xcode.xip   # once, takes a while
   ```

   `xcross setup` also installs `usbmuxd`, `usbutils`, and `libimobiledevice-utils` for USB device access and diagnostics.

## 🔑 Authentication

xcross talks to Apple's Developer Services directly. Two options:

### Apple ID (free account works)

```sh
xcross auth --apple-id you@example.com
```

The command prompts for your password and 2FA code, then stores **only** the resulting Developer Services session — never your password.

Machine attestation uses Android ADI libraries (`libCoreADI.so`, `libstoreservicescore.so`):

- **Windows x64 / Linux x86_64** — downloaded automatically from the Apple Music APK into `%APPDATA%\xcross\adi-libs` (Windows) or `~/.config/xcross/adi-libs` (Linux) on first use.
- **Other architectures** — extract the matching APK slice yourself and pass `--adi-library-dir`.

### App Store Connect API key

```sh
xcross auth --issuer-id <uuid> --key-id <id> --private-key /path/to/AuthKey.p8
```

## 🚀 Quick start

```sh
# 1. One-time machine setup (see Installation above)
xcross setup
xcross sdk install ~/Downloads/Xcode.xip
xcross auth --apple-id you@example.com

# 2. Once per device reconnect: mount DDI + start the RSD tunnel
#    (Administrator PowerShell on Windows; root on Linux)
xcross tunnel

# 3. Build, sign, install, launch, hot-reload
cd my_flutter_app
xcross flutter run

# 4. Optional: wire up your IDE
xcross ide vscode      # or: xcross ide idea
```

While the app is running:

| Key | Action |
|---|---|
| `r` | 🔥 Hot reload |
| `R` | ♻️ Hot restart |
| `q` / `Ctrl-C` / `Ctrl-D` | Quit |

With multiple iPhones connected, an interactive terminal shows a numbered device picker; pass `-u <UDID>` for CI or piped runs.

## 📖 Command reference

| Command | Description |
|---|---|
| `xcross setup` | Install host dependencies (apt packages, `pymobiledevice3`) |
| `xcross sdk install <Xcode.xip>` | Extract a private Darwin Swift SDK from an Xcode archive |
| `xcross auth` | Save Apple ID or App Store Connect credentials |
| `xcross tunnel` | Mount the Developer Disk Image + start the iOS 17+ RSD tunnel |
| `xcross flutter build` | Build a debug `.app` (or `.ipa` with `-i`) |
| `xcross flutter run` | Build → sign → install → launch → hot reload |
| `xcross flutter dap` | Run the Debug Adapter Protocol server (used by IDEs) |
| `xcross ide vscode` | Upsert `.vscode/*` for Run & Debug / Hot Reload |
| `xcross ide idea` | Write a JetBrains DAP run configuration (needs LSP4IJ) |
| `xcross completion` | Print a shell-completion script |

<details>
<summary><b><code>xcross flutter build</code> options</b></summary>

```text
-t, --target <path>          entrypoint (default: lib/main.dart)
-D, --dart-define k=v        repeatable
    --dart-define-from-file  .json / .env, repeatable
    --[no-]pub               run flutter pub get first (default: on)
    --build-name             CFBundleShortVersionString
    --build-number           CFBundleVersion
    --flavor                 flavor entrypoint selection
-i, --ipa                    package an .ipa instead of an .app
```

Output goes to `build/xcross-ios/<appName>.app`.
</details>

<details>
<summary><b><code>xcross flutter run</code> options</b></summary>

Shares all build options above, plus:

```text
-d, --device-id              device id or name
-u, --udid                   device UDID; wins if both selectors are set
    --usb / --wifi
    --device-connection      attached | wireless | both
    --route
-a, --dart-entrypoint-args   repeatable
-v, --verbose
```
</details>

## 🔌 Flutter plugins

Swift Package Manager iOS plugins work on both Windows and Linux. Their native code is compiled against the extracted Darwin SDK into `Frameworks/libFlutterPluginsGenerated.dylib` and registered by the generated runner.

Plugins that only ship a CocoaPods podspec are currently **skipped with a warning** — prefer plugin releases that include `ios/<package_name>/Package.swift`.

## 🪪 Bundle identity

The bundle id is read from the Flutter iOS project, using the same sources as Flutter's own tooling on non-macOS hosts:

1. A literal `CFBundleIdentifier` in `ios/Runner/Info.plist` (no `$(…)` variables), otherwise
2. the first `PRODUCT_BUNDLE_IDENTIFIER` in `ios/Runner.xcodeproj/project.pbxproj`.

The packed `.app`'s `Info.plist` is always derived from `ios/Runner/Info.plist` when present.

## 🧩 IDE integration

### VS Code

```sh
xcross ide vscode
```

Writes the DAP shim and upserts an xcross launch entry + DAP settings into `.vscode/`. Press **F5** to build, sign, install, and launch. Hot Reload / Restart buttons drive the same `r`/`R` commands as the CLI, and DevTools attaches to the same VM Service connection.

- Works in VS Code forks with the Dart-Code extension installed.
- The xcross launch config sets `"xcross": true`; other Flutter launch configs in the workspace keep working — sessions without that flag are handed to Flutter's own debug adapter.
- For multiple iPhones, set `"args": ["--udid", "<UDID>"]` on the xcross entry; re-running the command preserves those args.
- Existing `launch.json` / `settings.json` are merged in place (xcross keys upserted, everything else kept). A second run is a no-op when already current.
- Run the *installed* `xcross`; the generated DAP shim records that binary's path.

### JetBrains IDEA / Android Studio

```sh
xcross ide idea
```

Writes `.run/xcross_ios_device.run.xml` — a shared [LSP4IJ](https://plugins.jetbrains.com/plugin/18229-lsp4ij) Debug Adapter Protocol run configuration that starts `xcross flutter dap` over stdio.

- Install the LSP4IJ plugin, then Debug **xcross: iOS device** (don't use Flutter's Run button — it still calls `flutter run`).
- Breakpoints and stepping use the DAP/VM Service path; Restart maps to hot restart. Console `r`/`R` still work.
- An existing `.run/xcross_ios_device.run.xml` is never overwritten.

## ❓ FAQ

<details>
<summary><b>Why can't it build release/AOT?</b></summary>

Flutter's `gen_snapshot` for iOS AOT only runs on macOS hosts — Dart does not cross-compile an iOS AOT executable from Windows/Linux. Debug (JIT) builds don't need it, which is exactly what xcross produces. Release builds still need Flutter's macOS toolchain.
</details>

<details>
<summary><b>What does <code>xcross tunnel</code> do, and why does it need elevation?</b></summary>

It mounts the Developer Disk Image and starts the `pymobiledevice3` RSD tunnel — the encrypted QUIC/TUN tunnel iOS 17+ requires for developer services. Creating the TUN interface needs an Administrator PowerShell on Windows or root on Linux. Run it once per device reconnect.
</details>

<details>
<summary><b>Does it support Compose Multiplatform?</b></summary>

Not yet. xcross currently builds Flutter applications.
</details>

<details>
<summary><b>Is my Apple password stored anywhere?</b></summary>

No. `xcross auth` performs the login handshake locally and persists only the resulting Developer Services session token.
</details>

---

## 🔬 Under the hood

xcross does not wrap or patch `flutter build ios` — that command simply refuses to run off-macOS. Instead, it re-implements the parts of Flutter's toolchain that matter for a debug device build, using the same engine artifacts, the same compilers, and the same device protocols the official tooling uses.

```text
xcross flutter build ──► FlutterPacker
   ├─ IosEngineCache        download engine artifacts pinned to the SDK's engine hash
   ├─ FlutterDebugBundler   frontend_server → app.dill → App.framework (JIT)
   ├─ SwiftPM plugins       swift build (Darwin SDK) → libFlutterPluginsGenerated.dylib
   ├─ RunnerShim            clang / ld64.lld → Runner Mach-O
   └─ assemble              Flutter.framework + Info.plist + flutter_assets → .app

xcross flutter run ──► build → in-process codesign → install
   └─ CoreDeviceLauncher    RSD tunnel → launch suspended → gdb-remote attach
        └─ HotReloadController   DevFS + VM Service ⇄ frontend_server
```

### 1. Engine artifacts, straight from Flutter's CDN

`IosEngineCache` reads the engine revision from your Flutter SDK (the same hash `flutter` itself pins) and downloads exactly what Flutter's tool would cache: the prebuilt **`Flutter.xcframework`**, the debug **`vm_snapshot_data`** / **`isolate_snapshot_data`** JIT snapshots, the host **`frontend_server`**, and the Flutter **patched Dart SDK**. Your app therefore runs on the *identical* engine binary an Xcode build would embed — xcross never rebuilds or modifies the engine.

### 2. Kernel compilation with `frontend_server`

In debug mode Flutter apps are not compiled to machine code — the Dart VM runs **kernel bytecode** (JIT). `FlutterDebugBundler` drives the same `frontend_server` the Flutter tool uses (against the patched SDK, with your `--dart-define`s and flavor entrypoint) to produce `app.dill`, then lays out `App.framework` exactly like Flutter does:

- `flutter_assets/kernel_blob.bin` — the kernel program
- `flutter_assets/vm_snapshot_data`, `isolate_snapshot_data` — VM heap seeds
- `AssetManifest.bin/json`, `FontManifest.json`, fonts and assets — generated in Dart from your `pubspec.yaml`, replicating Flutter's asset bundling
- The `App.framework` *binary* in a debug build is only a stub — xcross compiles that stub with `clang` targeting `arm64-apple-ios` and writes the framework's `Info.plist` itself.

Because the app is pure JIT, no `gen_snapshot` is needed — which is precisely what makes macOS unnecessary (and why release/AOT is out of scope).

### 3. Native code without Xcode

- **Darwin SDK** — `darwin_sdk_kit` unpacks `Xcode.xip` with pure-Dart **xar**, **pbzx**, and **cpio** readers and assembles a Swift SDK bundle (iOS sysroot + frameworks) usable by upstream Swift/LLVM on Windows and Linux.
- **Runner** — the `Runner` executable (Flutter's `AppDelegate`/`main` shim) is compiled with `clang` and linked with `ld64.lld`, LLVM's Mach-O linker, against `Flutter.xcframework` from the SDK above.
- **Plugins** — SwiftPM iOS plugins are built with `swift build` against the same SDK into a single `libFlutterPluginsGenerated.dylib`, with a generated registrant mirroring Flutter's `GeneratedPluginRegistrant`. A Mach-O rewriter fixes install names and rpaths so the dylibs resolve inside the `.app` bundle.

### 4. Signing and device install, natively

`apple_developer_kit` implements Apple's **GrandSlam** login (with ADI machine attestation via the Android libraries), Developer Services provisioning (certificates, device registration, provisioning profiles), and **in-process Mach-O code signing** — no `codesign`, no `ldid`. Installation goes over the standard device protocols via `pymobiledevice3`.

### 5. iOS 17+ CoreDevice launch

iOS 17 replaced the old debug-launch path with **CoreDevice** over an encrypted **RSD tunnel**. `xcross tunnel` mounts the Developer Disk Image and brings the tunnel up; `CoreDeviceLauncher` then launches the app **suspended**, attaches a minimal **gdb-remote** client (the same protocol `debugserver` speaks) to resume and supervise the process, and port-forwards the **Dart VM Service** from the phone to localhost.

### 6. Hot reload: a faithful DevFS reimplementation

Hot reload is pure Flutter-internals territory, reimplemented protocol-for-protocol:

1. A long-lived `frontend_server` session (from `frontend_server_kit`) holds incremental compile state; a file watcher tracks your `lib/`.
2. On `r`, changed files are recompiled to an **incremental dill**, which is gzip-uploaded to the device via the VM Service's HTTP **DevFS** endpoint (`_createDevFS` + `PUT` — the same `org-dartlang-devfs://` filesystem Flutter's tool uses).
3. xcross calls `reloadSources` on the root isolate, then triggers `ext.flutter.reassemble` so the widget tree rebuilds.
4. `R` (hot restart) resets the compiler, uploads a full dill, and re-runs the app in each `FlutterView` via `_flutter.listViews` / run-in-view — matching Flutter's hot restart semantics.
5. The `frontend_server` is also registered as the VM Service's **expression compiler**, so debugger watch/evaluate works on-device.

### 7. IDE debugging via DAP

`xcross_dap` implements a **Debug Adapter Protocol** server that routes launch/attach, breakpoints, stepping, and hot-reload requests to the same VM Service connection. VS Code reaches it through a shim that intercepts launch configs marked `"xcross": true` (everything else falls through to Flutter's own adapter); JetBrains IDEs reach it through an LSP4IJ DAP run configuration.

### Package map

| Package | Role |
|---|---|
| `xcross_flutter` | Build pipeline: packer, debug bundler, engine cache, plugins, hot reload |
| `apple_developer_kit` | GrandSlam/ADI auth, App Store Connect, provisioning, Mach-O signing |
| `darwin_sdk_kit` | Pure-Dart xar/pbzx/cpio extraction of `Xcode.xip` → Darwin Swift SDK |
| `dart_mobile_device` | Device transports, RSD tunnel discovery, gdb-remote client, port forwarding |
| `frontend_server_kit` | Incremental kernel compiler session management |
| `xcross_dap` | Debug Adapter Protocol server for IDEs |
| `cli_kit` | Process, logging, privileges, download utilities |

## 📄 License

[MIT](LICENSE)
