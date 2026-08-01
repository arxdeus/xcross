<div align="center">

# xcross

[![Integration Tests](https://img.shields.io/github/actions/workflow/status/arxdeus/xcross/integration.yml?branch=main&style=flat-square&label=tests)](https://github.com/arxdeus/xcross/actions/workflows/integration.yml)
[![Latest release](https://img.shields.io/github/v/release/arxdeus/xcross?style=flat-square&label=release)](https://github.com/arxdeus/xcross/releases)
[![GitHub stars](https://img.shields.io/github/stars/arxdeus/xcross?style=flat-square&label=stars)](https://github.com/arxdeus/xcross/stargazers)
[![Open issues](https://img.shields.io/github/issues/arxdeus/xcross?style=flat-square)](https://github.com/arxdeus/xcross/issues)
![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20Windows-3C873A?style=flat-square)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square)](https://opensource.org/licenses/MIT)

**Build, run, and hot-reload Flutter iOS apps from Linux or Windows - no Xcode or macOS.**

⭐ If xcross saves you a Mac, star the repo.

[Install](#install) • [Windows](#windows-native) • [Quick start](#quick-start) • [Commands](#commands) • [VS Code](#vs-code) • [FAQ](#faq)

</div>

xcross reimplements the Flutter iOS build pipeline and the iOS 17+ CoreDevice launch protocol in pure Dart. Linux uses [xtool](https://github.com/xtool-org/xtool); Windows uses the bundled native signing bridge plus `pymobiledevice3`.

- 🐧🪟 **Linux and native Windows** - no Xcode, macOS, WSL, or Windows Swift toolchain
- 🔥 **Hot reload on device** - `r` reload, `R` restart, over the iOS 17+ RSD tunnel
- 📦 **Real signing & install** - with your Apple ID or App Store Connect API key
- ⚙️ **Pure Dart pipeline** - `frontend_server` → `clang` → `ld64.lld` → `.app`/`.ipa`

> [!IMPORTANT]
> Debug builds only - no release/AOT (that still needs macOS's `flutter_tools assemble`).

---

## Requirements

### Linux

| Tool                              | Installation                                                                                                  |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| Swift (runs `xtool`)              | [swift.org/install/linux](https://www.swift.org/install/linux/)[^1]                                           |
| `xtool`                           | [xtool-org/xtool](https://github.com/xtool-org/xtool)                                                         |
| Flutter SDK                       | [flutter.dev](https://flutter.dev)                                                                            |
| Darwin SDK                        | `xtool sdk install <Xcode.xip>` (grab `Xcode.xip` from [xcodereleases.com](https://xcodereleases.com/) first) |
| `clang`                           | `sudo apt install clang`                                                                                       |
| Python 3 (runs `pymobiledevice3`) | `sudo apt install python3 python3-pip`                                                                        |
| `pymobiledevice3`                 | `pip3 install -U pymobiledevice3`                                                                             |
| `usbmuxd` (USB device access)     | `sudo apt install usbmuxd`                                                                                    |
| `usbutils` (`lsusb`, for checking the phone shows up at all) | `sudo apt install usbutils`                                                        |
| `libimobiledevice-utils` (device diagnostics, e.g. `ideviceinfo`) | `sudo apt install libimobiledevice-utils`                                    |

You can install most of these packages via `xcross setup`

[^1]: The installer lists any missing system packages it needs - install all of them (via `apt`/your distro's package manager) after `swift` installation, or `swift` won't build correctly.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/arxdeus/xcross/main/install.sh | sh
```

## Windows (native)

Download `xcross-windows-x64.zip` from [Releases](https://github.com/arxdeus/xcross/releases), extract it, and put that directory on `PATH`. The archive includes `xcross.exe`, `zsign.exe`, and the x86 `xcross-aoskit.exe` authentication bridge.

Install these prerequisites:

1. [Flutter](https://flutter.dev), Python 3, and `pymobiledevice3` (`py -m pip install -U pymobiledevice3`).
2. Official [LLVM for Windows](https://github.com/llvm/llvm-project/releases), with `clang.exe` and `ld64.lld.exe` on `PATH`.
3. The **desktop/website editions** of both iTunes and iCloud, not the Microsoft Store editions. They provide Apple Mobile Device support and the x86 `AOSKit.dll` used for Apple ID authentication.
4. `Xcode.xip`, then extract only its iPhoneOS SDK without Xcode or Swift:

```powershell
xcross setup
xcross sdk install C:\Downloads\Xcode.xip
xcross auth --apple-id you@example.com
```

The auth command prompts for the password and 2FA code, then stores only the resulting Developer Services session. App Store Connect API-key authentication remains available with `--issuer-id`, `--key-id`, and `--private-key`.

Native Windows launch currently requires iOS 17+ and a plugin-free Flutter app. Before each reconnect, open PowerShell with **Run as administrator** and run `xcross prepare`.

## Quick start

### Linux

```sh
xcross setup                     # install apt requirements
xcross prepare                   # once per reconnect: mount DDI, start the RSD tunnel
cd my_flutter_app
xcross flutter run [-u <UDID>]   # build, install, launch, hot reload
xcross vscode                    # wire up Run & Debug / Hot Reload in VS Code for use via F5
```

### Windows

```powershell
# Administrator PowerShell, once per reconnect:
xcross prepare

# Normal terminal:
cd my_flutter_app
xcross flutter run -u <UDID>
```

## Commands

```text
xcross auth             save native Apple ID or App Store Connect credentials
xcross sdk install      extract the iPhoneOS SDK from Xcode.xip
xcross prepare          mount DDI + start the iOS 17+ RSD tunnel
xcross flutter build    build a debug .app (or .ipa with -i)
xcross flutter run      build → sign → install → launch → hot reload
xcross vscode           write .vscode/* for Run & Debug / Hot Reload
xcross completion       print a shell-completion script
```

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

**`xcross flutter run`** - shares `--target`/`--dart-define`/`--pub`/`--flavor` with `build`, plus:

```text
-d, --device-id     flutter-style
-u, --udid          xtool-style, wins if both are set
    --usb / --wifi / --device-connection attached|wireless|both
    --route
-a, --dart-entrypoint-args
-v, --verbose
```

`r` reload · `R` restart · `q` / Ctrl-C / Ctrl-D quit. Multiple devices → numbered picker, or pass `-u`. Hot reload needs iOS 17+; older devices require the Linux/xtool backend.

## Configuration

Optional `xtool.yml` at the project root:

```yaml
version: 1
orgID: com.example                # bundle id = <orgID>.<appName>
# bundleID: com.you.app           # or a literal bundle id - wins if both are set
infoPath: ios/Runner/Info.plist   # optional
```

No file? Defaults to `com.example`.

## VS Code

```sh
xcross vscode
```

Writes `.vscode/launch.json`, `settings.json`, and a small DAP shim. Press F5 - it builds, signs, installs, and launches; the Hot Reload/Restart buttons drive the same `r`/`R` as the CLI, and DevTools works over the same VM Service connection.

- Works the same in any VS Code fork with the Dart-Code extension installed - Cursor, Windsurf, Trae, VSCodium, code-server, ...
- Multiple iPhones → set `"args": ["--udid", "<UDID>"]` in `launch.json`.
- Only the DAP shim gets overwritten each run - existing `launch.json`/`settings.json` are left alone (a merge snippet is printed instead).
- Run the *installed* `xcross`, not `dart run bin/xcross.dart vscode` - the shim bakes in that binary's path.
- Breakpoints, stepping, call stack, variables and expression eval all work, backed by a direct Dart VM Service connection (via `package:dds`'s debug adapter).

## FAQ

<details>
<summary>Why can't it build release/AOT?</summary>

Dart's [`dart compile` cross-compilation](https://dart.dev/tools/dart-compile#cross-compilation-exe) doesn't target iOS yet - that step still needs a real Mac.
</details>

<details>
<summary>Does it support the simulator?</summary>

No - arm64 device builds only, minimum iOS 13.
</details>

<details>
<summary>Does it support JetBrains IDEs (IntelliJ / Android Studio)?</summary>

Not yet - only VS Code (and its forks) is supported right now.
</details>

<details>
<summary>Does it support Compose Multiplatform (CMP)?</summary>

In progress, but not yet - xcross is Flutter-only for now.
</details>

<details>
<summary>Does hot reload work on every iOS version?</summary>

Only iOS 17+. And don't detach mid-session there - it kills the app (`CS_DEBUGGED`).
</details>

<details>
<summary>What does <code>xcross prepare</code> actually do?</summary>

On iOS 17+ it mounts the Developer Disk Image and starts the `pymobiledevice3` RSD tunnel (needs root on Linux or an Administrator PowerShell on Windows). It never stops its own tunnels, so re-running after a reconnect is always safe.
</details>

<details>
<summary>I have multiple devices plugged in - now what?</summary>

Pass `-u/--udid` (required for CI/piped runs); in an interactive terminal you'll get a numbered picker instead.
</details>

<details>
<summary>Why does <code>swift sdk</code> fail with <code>libxml2.so.2: cannot open shared object file</code> on Ubuntu 26.04?</summary>

Ubuntu 26.04 ships `libxml2.so.16` (`libxml2-16`), while Swift toolchains (e.g. 6.3.3 via swiftly) still link against the older SONAME `libxml2.so.2`. Installing `libxml2-16` doesn't provide that name. Fix it with a compatibility symlink:

```sh
sudo ln -sf /usr/lib/x86_64-linux-gnu/libxml2.so.16 /usr/lib/x86_64-linux-gnu/libxml2.so.2
```

</details>

## How it works

```text
flutter build → FlutterPacker
  ├─ FlutterDebugBundler   frontend_server → App.framework
  ├─ RunnerShim            clang / ld64.lld → Runner
  └─ Info.plist

flutter run → build → DeviceBackend → sign/install → launch
```

### Build

1. **Resolve the Flutter SDK** - `FLUTTER_ROOT`, then a `.fvm/flutter_sdk` symlink, then `flutter` on PATH - and run `flutter pub get` (unless `--no-pub`).
2. **`FlutterDebugBundler`** fetches/caches Flutter's iOS engine artifacts, compiles your Dart code to a kernel via `frontend_server` (JIT - the reason it's debug-only), and links a small stub dylib into `App.framework`.
3. **`RunnerShim`** compiles a generated Objective-C `Runner` host (the `AppDelegate`/`SceneDelegate` boilerplate that embeds the Flutter engine) with `clang`, then links it with `ld64.lld` - no Xcode linker is used.
4. **`Info.plist`** gets patched with the required keys (bundle id, executable, min OS version, device family, ...) and everything is stitched into `<AppName>.app`. Pass `-i/--ipa` to zip it into a `.ipa` too - pure Dart, no external `zip` binary.

### Run

Runs the build above, then:

1. **`DeviceBackend`** uses `xtool` when present. Otherwise the native backend provisions with the saved Apple ID session or App Store Connect key, signs with bundled `zsign`, and installs with `pymobiledevice3`.
2. **iOS 17+ → `CoreDeviceLauncher`**: brings up the `pymobiledevice3` RSD tunnel, launches the app *suspended*, then attaches over the GDB-remote protocol and resumes it - keeping a live debugger connection open for the whole session (why detaching mid-session kills the app). With hot reload on, it also keeps a `frontend_server` and the Dart VM Service connected for `r`/`R`/`q`.
3. **Pre-17 → `DebugLauncher`**: uses `xtool launch`. Native Windows builds can sign and install for older devices, but native launch/hot reload requires iOS 17+.

`xcross dap` drives this exact same `flutter run` pipeline, just fed `r`/`R`/`q` over stdin instead of a terminal - that's what powers [VS Code](#vs-code).
