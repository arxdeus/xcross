# xcross

[![license: MIT](https://img.shields.io/badge/license-MIT-purple.svg)](https://opensource.org/licenses/MIT)
[![platform: Linux](https://img.shields.io/badge/platform-Linux-blue.svg)](#requirements)
[![Dart](https://img.shields.io/badge/dart-%5E3.6.0-0175C2.svg)](https://dart.dev)

**Build, run, and hot-reload Flutter and Kotlin/Compose Multiplatform iOS apps from Linux — no Xcode, no macOS.**

xcross is a Dart CLI. It reimplements the Flutter iOS build pipeline and iOS 17+ CoreDevice launch in pure Dart, and delegates signing, install, and device discovery to the [`xtool`](https://github.com/xtool-org/xtool) binary. For Kotlin/Compose Multiplatform it runs a Kotlin/Native build (`konanc` + `ld64.lld`) end to end on Linux.

Key properties:

- 🐧 **Linux-native** — no Xcode, no macOS, no Rosetta shim for the build itself
- 🔥 **Hot reload on device** — `r` reload, `R` restart, over the iOS 17+ CoreDevice/RSD tunnel
- 📦 **Real signing & install** — handed off to `xtool` with your saved credentials
- 🎯 **Flutter + Compose/KMP** — one CLI, one output layout, one device stack
- 🧰 **Rootless toolchain** — Kotlin/Native auto-downloads into `$HOME/.konan`; the toolchain setup never runs `sudo`/`apt` (the iOS 17+ RSD tunnel still needs root — see Gotchas)
- ⚙️ **Pure Dart pipeline** — `frontend_server` → `clang` → `ld64.lld` → `.app`/`.ipa`

---

## Overview

xcross gives you a Linux path through the iOS build pipeline that normally requires a Mac.

- **Flutter iOS** — debug/JIT `.app` or `.ipa`, hot reload on device
- **Compose / KMP iOS** — full Gradle → `konanc` → `clang` → `ld64.lld` → `.app` bundle
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
# Flutter: build + install + hot reload on device
cd my_flutter_app
xcross flutter run -u <UDID>       # r = reload, R = restart, q = quit

# Flutter: just build the .app
xcross flutter build               # → build/xtool-ios/<AppName>.app

# Compose / KMP  (first run auto-downloads Kotlin/Native — see `compose setup`)
xcross compose setup               # optional: fetch the K/N toolchain up front (no root)
xcross compose run -u <UDID>       # debug by default
xcross compose build -c release -i # release .ipa
```

---

## Requirements

| Tool | Why |
|------|-----|
| `xtool` on PATH | sign, install, device discovery — run `xtool auth` first |
| Darwin SDK | `xtool sdk install <Xcode.xip>` → `~/.swiftpm/swift-sdks/darwin.artifactbundle` |
| Flutter SDK | on PATH, or `FLUTTER_ROOT`, or `.fvm/flutter_sdk` symlink |
| `pymobiledevice3` | RSD tunnel for iOS 17+ (needs root) |
| `zip` | only for `--ipa` |
| Dart `^3.6.0` | to build xcross itself |

**Compose / KMP** also needs JDK (`JAVA_HOME`), stock LLVM `lld` + `clang`, and builds **amd64 only** (K/N has no linux-aarch64 prebuilt; use Rosetta on Apple Silicon). The heavy Kotlin/Native pieces (the `linux-x86_64` prebuilt + `ios_arm64` overlay + warmed cache) are **downloaded automatically, without root**, into `$HOME/.konan` on first use — or run `xcross compose setup` up front. JDK/clang/lld are OS prerequisites you install with your package manager (**xcross never runs `sudo`/`apt`**). The prebuilt Docker image bakes everything in.

---

## Commands

### `xcross flutter build`

Builds a Flutter iOS `.app` (debug). Output: `build/xtool-ios/<AppName>.app`.

| Flag | Default | Description |
|------|---------|-------------|
| `-t, --target` | `lib/main.dart` | App entrypoint |
| `-D, --dart-define` | — | `KEY=VALUE` (repeatable) |
| `--dart-define-from-file` | — | Defines from `.json`/`.env` |
| `--[no-]pub` | `true` | Run `flutter pub get` first |
| `--build-name` | — | `CFBundleShortVersionString` |
| `--build-number` | — | `CFBundleVersion` |
| `--flavor` | — | App flavor (limited) |
| `-s, --sign` / `--codesign` | — | Mark for signing (actual sign at install) |
| `-i, --ipa` | — | Output `.ipa` instead of `.app` |

> `--sign` alone is a no-op: `xtool` has no standalone sign command. Signing runs at `xtool install`. Use `xcross flutter run` or `xtool install <app>` to sign.

### `xcross flutter run`

Build → sign + install (via `xtool`) → launch → hot reload.

| Flag | Default | Description |
|------|---------|-------------|
| `-t, --target` | `lib/main.dart` | Entrypoint |
| `-D, --dart-define` / `--dart-define-from-file` | — | Dart defines |
| `--[no-]pub` | `true` | `flutter pub get` first |
| `--flavor` | — | App flavor (limited) |
| `-d, --device-id` | — | Device id/name (flutter-style) |
| `-u, --udid` | — | Device UDID (xtool-style) |
| `--usb` / `--wifi` | — | Restrict discovery |
| `--device-connection` | `both` | `attached` \| `wireless` \| `both` |
| `--route` | — | Initial route |
| `-a, --dart-entrypoint-args` | — | Args to `main()` (repeatable) |
| `-v, --verbose` | — | Verbose |

Keys while running: `r` reload, `R` restart, `q`/Ctrl-C quit. `--udid` wins over `--device-id`. With multiple devices, a TTY shows a numbered picker; non-TTY (CI/piped) fails fast and asks for `--udid`.

### `xcross compose build`

Builds a KMP iOS `.app` (Gradle → `konanc` → `clang` → `ld64.lld` → bundle). Output: `build/xtool-ios/<AppName>.app`.

| Flag | Default | Description |
|------|---------|-------------|
| `-c, --configuration` | `release` | `debug` \| `release` |
| `-s, --sign` / `--codesign` | — | Mark for signing (actual sign at install) |
| `-i, --ipa` | — | Output `.ipa` |

### `xcross compose run`

Build → sign + install → launch. Same device stack as `flutter run`.

| Flag | Default | Description |
|------|---------|-------------|
| `-c, --configuration` | `debug` | `debug` \| `release` |
| `-d, --device-id` / `-u, --udid` | — | Device selector |
| `--usb` / `--network` / `--all` | `all` | Discovery mode |
| `-a, --dart-entrypoint-args` | — | Args to the binary (repeatable) |

> Compose hot reload isn't implemented yet; the process stays attached so the K/N debug binary keeps its `CS_DEBUGGED` flag.

### `xcross compose setup`

Downloads the Kotlin/Native toolchain for `xcross compose` — the **rootless** port of the old `setup-compose.sh`. Fetches the Kotlin/Native `linux-x86_64` prebuilt, overlays the `ios_arm64` target from the macOS prebuilt, and warms `konanc`'s native dependency cache — all into a user-writable dir (`$HOME/.konan`). **xcross never runs `sudo`/`apt`.**

System packages (JDK 21, `clang`, `lld`) are prerequisites: if any is missing, this reports it with an install hint (e.g. `sudo apt-get install openjdk-21-jdk-headless lld`) instead of installing it for you.

`compose build`/`run` call this automatically when the K/N caches are missing, then re-validate and continue. Run it explicitly to pre-warm (e.g. in CI) or to see exactly what's needed.

| Flag | Description |
|------|-------------|
| `--check` | Validate only; download nothing. Prints an actionable report. |
| `--force` | Re-download even if the toolchain already looks ready. |

```sh
xcross compose setup                   # fetch K/N (first time, ~450 MB downloads)
xcross compose setup --check           # just report readiness
```

The Kotlin/Native **version is derived from your project** (`gradle/libs.versions.toml` → `kotlin = "…"`, else `gradle.properties`), so it matches the tree the KMP Gradle build installs — if `~/.konan` already has it (from a prior `./gradlew` build), the linux prebuilt download is skipped and only the `ios_arm64` overlay is fetched. Override with `KN_VERSION`.

Tunables: `KN_VERSION` (default: project's Kotlin version, else `2.2.20`), `KONAN_ROOT` (default `$HOME/.konan`). Disable auto-download with `XCROSS_NO_AUTO_SETUP=1` (build/run then fail with guidance). Skip validation entirely with `XCROSS_SKIP_PREFLIGHT=1`.

---

## Configuration — `xtool.yml`

Optional file at the project root (schema version 1). Without it, xcross defaults to the `com.example` org.

```yaml
version: 1
orgID: com.example              # bundle = <orgID>.<appName>
# bundleID: com.example.MyApp   # OR set a literal bundle id
product: myApp                  # optional; compose derives the app name
infoPath: ios/Runner/Info.plist # optional override
entitlementsPath: ...           # optional
iconPath: assets/icon.png       # optional; must be .png
resources:                      # optional extra files
  - assets/config.json
```

Set either `orgID` or `bundleID` (not both). `iconPath` must be `.png`.

---

## Environment variables

| Var | Purpose | Default |
|-----|---------|---------|
| `FLUTTER_ROOT` | Flutter SDK location | parent of `which flutter` |
| `XCROSS_LD64LLD` | `ld64.lld` path (x86_64) | `DarwinSdk.ld64lld` |
| `LX_KN` | Kotlin/Native linux-x86_64 root | `/opt/konan/...-2.2.20` |
| `JAVA_HOME` | JDK for `konanc` + Gradle | system |
| `KONAN_DATA_DIR` | K/N dependency cache | `~/.konan` |
| `KN_VERSION` | K/N version `compose setup` downloads | project's Kotlin version, else `2.2.20` |
| `KONAN_ROOT` | Where `compose setup` downloads K/N (user-writable) | `$HOME/.konan` |
| `XCROSS_NO_AUTO_SETUP` | Validate but never auto-download for `compose build/run` | unset |
| `XCROSS_SKIP_PREFLIGHT` | Skip the compose toolchain check entirely | unset |

---

## How it works

```
xcross
├── flutter build → FlutterPacker
│     ├─ FlutterDebugBundler  frontend_server → App.framework (kernel + stub dylib)
│     ├─ RunnerShim           clang / ld64.lld → ObjC Runner
│     └─ Info.plist generation
├── flutter run   → build → XtoolCli.install → CoreDeviceLauncher (iOS 17+, hot reload)
│                                            → DebugLauncher      (pre-17)
├── compose build → ComposePacker (Gradle → konanc → xcframework → clang / ld64.lld → .app)
└── compose run   → build → XtoolCli.install → CoreDeviceLauncher / DebugLauncher
```

Key files: `bin/xcross.dart` (entrypoint), `lib/src/cli/runner.dart` (command wiring), `lib/src/build/flutter_packer.dart`, `lib/src/build/compose_packer.dart`, `lib/src/device/core_device_launcher.dart`, `lib/src/models/config/pack_schema.dart`.

---

## Gotchas

- **Debug only.** Release / AOT needs the macOS `flutter_tools assemble` path.
- **`--sign` alone does nothing** — signing happens at `xtool install`.
- **iOS 17+ needs `pymobiledevice3` + root** for the RSD tunnel. Mount the DDI: `sudo pymobiledevice3 mounter auto-mount`.
- **Compose is amd64 only.**
- **First compose build/run auto-downloads Kotlin/Native** (~450 MB) into `$HOME/.konan` — no root. JDK / clang / lld must already be installed (xcross won't `sudo`/`apt` for you). Set `XCROSS_NO_AUTO_SETUP=1` to opt out.
- **Install a Darwin SDK first:** `xtool sdk install <Xcode.xip>`.
- **Multiple devices?** A TTY prompts with a numbered picker; CI/piped runs fail fast — pass `-u/--udid` or `-d`.
- **JIT stays attached** — detaching kills the app (`CS_DEBUGGED`).

---

## Integration tests

CI runs two end-to-end build jobs on every pull request and push to `main` (see [`.github/workflows/integration.yml`](.github/workflows/integration.yml)):

| Job | Runner | What it tests |
|-----|--------|---------------|
| `flutter-build` | `ubuntu-24.04` | `xcross flutter build` on a fresh `flutter create` sample → asserts ARM64 Mach-O `.app` |
| `compose-build` | `ubuntu-24.04` (amd64) | `xcross compose build -c debug` on the vendored self-contained KMP fixture at `test/fixtures/kmp_sample/` → asserts ARM64 Mach-O `.app` |

Both jobs require the Darwin SDK (`~/.swiftpm/swift-sdks/darwin.artifactbundle`).

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

## License

MIT — see [LICENSE](LICENSE).
