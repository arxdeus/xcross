# xcross

[license: MIT](https://opensource.org/licenses/MIT)
[platform: Linux](#requirements)
[Dart](https://dart.dev)

**Build, run, and hot-reload Flutter iOS apps from Linux — no Xcode, no macOS.**

xcross is a Dart CLI. It reimplements the Flutter iOS build pipeline and iOS 17+ CoreDevice launch in pure Dart, and delegates signing, install, and device discovery to the `[xtool](https://github.com/xtool-org/xtool)` binary.

Key properties:

- 🐧 **Linux-native** — no Xcode, no macOS, no Rosetta shim for the build itself
- 🔥 **Hot reload on device** — `r` reload, `R` restart, over the iOS 17+ CoreDevice/RSD tunnel
- 📦 **Real signing & install** — handed off to `xtool` with your saved credentials
- ⚙️ **Pure Dart pipeline** — `frontend_server` → `clang` → `ld64.lld` → `.app`/`.ipa`

---

## Overview

xcross gives you a Linux path through the iOS build pipeline that normally requires a Mac.

- **Flutter iOS** — debug/JIT `.app` or `.ipa`, hot reload on device
- **Device launch** — iOS 17+ via RSD tunnel + GDB-remote, pre-17 via `xtool launch`
- **Codesign + install** — real signing, delegated to `xtool` with your Apple credentials

> xcross builds **debug only**. Release AOT still requires the macOS-only `flutter_tools assemble` path.

---

## Install

Grab the latest prebuilt binary from GitHub Releases (Linux x64/arm64). The script detects your architecture, downloads the matching binary, installs it to `/usr/local/bin`, and makes it executable (uses `sudo` if needed):

```sh
curl -fsSL https://raw.githubusercontent.com/arxdeus/xcross/main/install.sh | sh
```

Pin a version or change the install dir:

```sh
XCROSS_VERSION=v1.2.3 INSTALL_DIR="$HOME/.local/bin" sh install.sh
```

Or build from source:

```sh
cd xcross
dart pub get
dart compile exe bin/xcross.dart -o /usr/local/bin/xcross
```

---

## Quick start

```sh
# One-time / after reconnect: mount DDI + start RSD tunnel (needs sudo)
xcross prepare

# Flutter: build + install + hot reload on device
cd my_flutter_app
xcross flutter run -u <UDID>       # r = reload, R = restart, q = quit

# Flutter: just build the .app
xcross flutter build               # → build/xtool-ios/<AppName>.app

# VS Code: wire up the Run & Debug / Restart / Hot Reload buttons
xcross vscode
```

---

## VS Code

```sh
cd my_flutter_app
xcross vscode
```

Writes `.vscode/launch.json`, `.vscode/settings.json` and `.vscode/xcross_dap.dart`, then press <kbd>F5</kbd>. No terminal session needed first — **Run & Debug** builds, signs, installs and launches on the device; the debug toolbar's **Hot Reload** and **Restart** drive the same reload/restart as `r` and `R`. App output goes to the Debug Console.

It works by pointing Dart-Code's `dart.customFlutterDapPath` at a small shim that starts `xcross dap`, a debug adapter that runs `xcross flutter run` and steers it over the existing `r`/`R`/`q` protocol.

### DevTools

Once the app is up, xcross reports the on-device VM Service URI to the editor, so **Open DevTools** and the debug toolbar's DevTools/widget-inspector buttons work — including the inspector embedded in the editor. Set `"dart.openDevTools": "flutter"` to open it automatically each run.

The VM Service lives on the phone behind an IPv6 RSD tunnel, and a bracketed IPv6 literal does not survive browsers, editor webviews or the editor's URI forwarding. So xcross forwards the port and publishes plain `ws://127.0.0.1:<port>/ws` instead — the same shape `flutter run` hands out.

Expression evaluation works too, which matters more than it sounds: the Flutter engine embeds no kernel compiler, so the VM asks a registered client to compile expressions. xcross serves that from the `frontend_server` it already runs for hot reload. Without it, DevTools probes with `Platform.isAndroid`, sees the eval fail, concludes the app is a profile build, and disables the **Flutter Inspector** and **Debugger** screens on a perfectly good debug build.

xcross runs no DDS in front of the VM Service, unlike `flutter run`, which has two consequences:

- The **Logging** screen only shows events from the moment DevTools connects — there is no replay of earlier logs.
- DevTools is a second client on the raw VM Service (xcross itself holds one for hot reload). Independent clients are fine, but nothing arbitrates between them: driving pause/resume from DevTools can confuse the reload path. Prefer the editor's own buttons for reload/restart.

- Several iPhones connected? Put the device in `launch.json`: `"args": ["--udid", "<UDID>"]`.
- `xcross vscode` only overwrites `xcross_dap.dart`; if `launch.json`/`settings.json` already exist it prints the snippet to merge yourself.
- `print()`, `debugPrint()` and `dart:developer log()` arrive over the VM Service, so they need hot reload to be available — the same condition as the Hot Reload button. The debugger attaches to an app that `pymobiledevice3` already launched, so it owns no stdio of its own to forward.
- `flutter test` sessions are passed through to the stock Flutter debug adapter.
- `dart.customFlutterDapPath` is workspace-wide: every *non-test* Flutter debug session in this folder goes through xcross to iOS. Don't add it to a workspace you also debug on Android/web from.
- No breakpoints or stepping — the buttons only. Use `xcross prepare` once for iOS 17+ as usual.

---

## Requirements

| Tool              | Why                                                                             |
| ----------------- | ------------------------------------------------------------------------------- |
| `xtool` on PATH   | sign, install, device discovery — run `xtool auth` first                        |
| Darwin SDK        | `xtool sdk install <Xcode.xip>` → `~/.swiftpm/swift-sdks/darwin.artifactbundle` |
| Flutter SDK       | on PATH, or `FLUTTER_ROOT`, or `.fvm/flutter_sdk` symlink                       |
| `pymobiledevice3` | RSD tunnel for iOS 17+ (needs root)                                             |
| `zip`             | only for `--ipa`                                                                |
| Dart `^3.6.0`     | to build xcross itself                                                          |

---

## Commands

### `xcross prepare`

Mount the Developer Disk Image and start the iOS 17+ RSD tunnel(s). Needs sudo once (password prompt). Leaves long-lived tunnel processes running.

Automates:

```sh
sudo pymobiledevice3 mounter auto-mount
sudo pymobiledevice3 lockdown start-tunnel
# also ensures: sudo pymobiledevice3 remote tunneld
```

Run after plugging in the phone (or after WSL/usbipd reconnect) before `xcross flutter run`.

### `xcross flutter build`

Builds a Flutter iOS `.app` (debug). Output: `build/xtool-ios/<AppName>.app`.

| Flag                        | Default         | Description                               |
| --------------------------- | --------------- | ----------------------------------------- |
| `-t, --target`              | `lib/main.dart` | App entrypoint                            |
| `-D, --dart-define`         | —               | `KEY=VALUE` (repeatable)                  |
| `--dart-define-from-file`   | —               | Defines from `.json`/`.env`               |
| `--[no-]pub`                | `true`          | Run `flutter pub get` first               |
| `--build-name`              | —               | `CFBundleShortVersionString`              |
| `--build-number`            | —               | `CFBundleVersion`                         |
| `--flavor`                  | —               | App flavor (sets `FLUTTER_APP_FLAVOR`)    |
| `-s, --sign` / `--codesign` | —               | Mark for signing (actual sign at install) |
| `-i, --ipa`                 | —               | Output `.ipa` instead of `.app`           |

> `--sign` alone is a no-op: `xtool` has no standalone sign command. Signing runs at `xtool install`. Use `xcross flutter run` or `xtool install <app>` to sign.

### `xcross flutter run`

Build → sign + install (via `xtool`) → launch → hot reload.

| Flag                                            | Default         | Description                      |
| ----------------------------------------------- | --------------- | -------------------------------- |
| `-t, --target`                                  | `lib/main.dart` | Entrypoint                       |
| `-D, --dart-define` / `--dart-define-from-file` | —               | Dart defines                     |
| `--[no-]pub`                                    | `true`          | `flutter pub get` first          |
| `--flavor`                                      | —               | App flavor (sets `FLUTTER_APP_FLAVOR`) |
| `-d, --device-id`                               | —               | Device id/name (flutter-style)   |
| `-u, --udid`                                    | —               | Device UDID (xtool-style)        |
| `--usb` / `--wifi`                              | —               | Restrict discovery               |
| `--device-connection`                           | `both`          | `attached` | `wireless` | `both` |
| `--route`                                       | —               | Initial route                    |
| `-a, --dart-entrypoint-args`                    | —               | Args to `main()` (repeatable)    |
| `-v, --verbose`                                 | —               | Verbose                          |

Keys while running: `r` reload, `R` restart, `q`/Ctrl-C quit. `--udid` wins over `--device-id`. With multiple devices, a TTY shows a numbered picker; non-TTY (CI/piped) fails fast and asks for `--udid`.

### `xcross vscode`

Writes `.vscode/launch.json`, `.vscode/settings.json` and `.vscode/xcross_dap.dart` into the current directory so the editor's **Run & Debug**, **Restart** and **Hot Reload** buttons drive `xcross flutter run`. See [VS Code](#vs-code). Existing `launch.json`/`settings.json` are never modified — the snippet to merge is printed instead.

---

## Configuration — `xtool.yml`

Optional file at the project root (schema version 1). Without it, xcross defaults to the `com.example` org.

```yaml
version: 1
orgID: com.example              # bundle = <orgID>.<appName>
# bundleID: com.example.MyApp   # OR set a literal bundle id
product: myApp                  # optional
infoPath: ios/Runner/Info.plist # optional override
entitlementsPath: ...           # optional
iconPath: assets/icon.png       # optional; must be .png
resources:                      # optional extra files
  - assets/config.json
```

Set either `orgID` or `bundleID` (not both). `iconPath` must be `.png`.

---

## Environment variables

| Var              | Purpose                  | Default                   |
| ---------------- | ------------------------ | ------------------------- |
| `FLUTTER_ROOT`   | Flutter SDK location     | parent of `which flutter` |
| `XCROSS_LD64LLD` | `ld64.lld` path (x86_64) | `DarwinSdk.ld64lld`       |

---

## How it works

```
xcross
├── flutter build → FlutterPacker
│     ├─ FlutterDebugBundler  frontend_server → App.framework (kernel + stub dylib)
│     ├─ RunnerShim           clang / ld64.lld → ObjC Runner
│     └─ Info.plist generation
└── flutter run   → build → XtoolCli.install → CoreDeviceLauncher (iOS 17+, hot reload)
                                             → DebugLauncher      (pre-17)
```

Key files: `bin/xcross.dart` (entrypoint), `lib/src/cli/runner.dart` (command wiring), `lib/src/build/flutter_packer.dart`, `lib/src/device/core_device_launcher.dart`, `lib/src/models/config/pack_schema.dart`.

---

## Gotchas

- **Debug only.** Release / AOT needs the macOS `flutter_tools assemble` path.
- `--sign` **alone does nothing** — signing happens at `xtool install`.
- **iOS 17+ needs** `pymobiledevice3` **+ root** for the RSD tunnel. Run `xcross prepare` (or mount manually: `sudo pymobiledevice3 mounter auto-mount`).
- **Install a Darwin SDK first:** `xtool sdk install <Xcode.xip>`.
- **Multiple devices?** A TTY prompts with a numbered picker; CI/piped runs fail fast — pass `-u/--udid` or `-d`.
- **JIT stays attached** — detaching kills the app (`CS_DEBUGGED`).

---

## Integration tests

CI runs an end-to-end build job on every pull request and push to `main` (see `[.github/workflows/integration.yml](.github/workflows/integration.yml)`):

| Job             | Runner         | What it tests                                                                           |
| --------------- | -------------- | --------------------------------------------------------------------------------------- |
| `flutter-build` | `ubuntu-24.04` | `xcross flutter build` on a fresh `flutter create` sample → asserts ARM64 Mach-O `.app` |

The job requires the Darwin SDK (`~/.swiftpm/swift-sdks/darwin.artifactbundle`).

**Providing the Darwin SDK to CI** — choose one:

1. **Repo secret (simplest):** Set `DARWIN_ARTIFACTBUNDLE_URL` to a `.tar.gz` URL that contains `darwin.artifactbundle/` at its root. The setup action downloads and verifies it on each run.
2. **Pre-warmed cache (faster):** Run the [Warm Darwin SDK cache](.github/workflows/warm-darwin-sdk.yml) workflow once via `workflow_dispatch` after setting the secret. Subsequent runs hit the cache (`darwin-artifactbundle-v1`) and skip the download.

To build the tarball locally:

```sh
xtool sdk install /path/to/Xcode.xip
tar -czf darwin.artifactbundle.tar.gz \
  -C ~/.swiftpm/swift-sdks darwin.artifactbundle
# Upload the .tar.gz; set DARWIN_ARTIFACTBUNDLE_URL repo secret to its URL.
```

---
