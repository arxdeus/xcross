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

[Watch the demo](https://youtu.be/L8xhsSMJ8fU) • [Install](#installation) • [Quick start](#quick-start) • [Wi-Fi](#run-over-wi-fi) • [Commands](#command-reference) • [IDE](#ide-integration) • [FAQ](#faq) • [Under the hood](#under-the-hood)

</div>

---

xcross reimplements the Flutter iOS build pipeline and the iOS 17+ CoreDevice launch protocol in pure Dart. It compiles your Flutter app with the official Swift and LLVM toolchains, signs it with your Apple ID or an App Store Connect API key, installs it on a physical iPhone, launches it, and gives you full hot reload - all from a Windows or Linux machine.

| Feature | Details |
|---|---|
| **Native Windows & Linux** | Runs directly on the host with official Swift and LLVM toolchains - no VM, no WSL, no macOS anywhere |
| **Hot reload & hot restart** | Full `r` / `R` workflow on a real iPhone over an iOS 17+ RSD tunnel |
| **Native signing & install** | Apple ID (free account works) or App Store Connect API key; signing runs in-process |
| **USB and Wi-Fi devices** | Pair wirelessly over a trusted USB connection, or directly from Paired Devices on iOS 27+ |
| **SwiftPM plugins** | Swift Package Manager iOS plugins compile on both Windows and Linux |
| **IDE debugging** | One command sets up VS Code (F5, breakpoints, DevTools) or JetBrains IDEs via DAP |
| **Direct build pipeline** | `frontend_server` → `clang` → `ld64.lld` → `.app` / `.ipa` - no Xcode build system involved |

> [!IMPORTANT]
> xcross produces **debug (JIT) device builds**. Release/AOT builds still require Flutter's macOS build tooling. Launching with xcross requires **iOS 17 or later** on the device.

## Requirements

Both platforms need the same five ingredients:

| Requirement | Purpose |
|---|---|
| [Flutter](https://flutter.dev) | Your app's SDK; xcross reuses its engine artifacts |
| [Swift toolchain](https://www.swift.org/install/) | Compiles SwiftPM plugins and runner glue code |
| [LLVM](https://releases.llvm.org/) (`clang`, `clang++`, `llvm-ar`, `ld64.lld` on `PATH`) | Compiles and links the iOS Mach-O binaries |
| Python 3 + [`pymobiledevice3`](https://github.com/doronz88/pymobiledevice3) | Device communication and the iOS 17+ RSD tunnel |
| A complete `Xcode.xip` ([xcodereleases.com](https://xcodereleases.com/)) | Processed **once** by `xcross sdk install` into a private Darwin Swift SDK |

> [!IMPORTANT]
> **Install the Swift toolchain before running `xcross setup` or `xcross sdk install`.** xcross never installs Swift for you on any host, and both commands refuse to run without it.
>
> `xcross sdk install` patches the Darwin SDK with the *selected* Swift toolchain's clang headers and records which toolchain that was. The resulting SDK is only usable by that toolchain, so changing Swift afterwards (`swiftly use`, `mise use`, a distro upgrade) means re-running `xcross sdk install`. Pick your Swift version first and stay on it.
>
> On Linux, `xcross setup` can also install Swift's *own* build dependencies. If that is why you are running it before Swift exists, use `xcross setup --no-swift-check`.

> [!NOTE]
> Download the Xcode archive from [xcodereleases.com](https://xcodereleases.com/) (requires an Apple ID). It is only used as SDK *input* - neither Xcode nor macOS is ever installed or executed. xcross extracts the iOS SDK and frameworks from the archive with its own pure-Dart xar/pbzx/cpio readers. Don't redistribute the extracted Apple SDK.

## Installation

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

   Open a new terminal after installing Swift so its `bin` directory is on `PATH`; both commands refuse to run without it. The SDK is tied to the Swift active here, so re-run `xcross sdk install` if you later switch Swift versions.

### Linux

1. One-line install:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/arxdeus/xcross/main/install.sh | sh
   ```

2. Install the Swift toolchain, which xcross does not install for you ([swiftly](https://www.swift.org/install/linux/) is the easiest route):

   ```sh
   curl -fsSL https://swiftlang.github.io/swiftly/swiftly-install.sh | bash
   swiftly install latest
   swift --version   # must work before the next step
   ```

   Swift needs a few distro packages of its own. If it will not start, run `xcross setup --no-swift-check` first, then install Swift and continue.

3. Let xcross install its distro dependencies and `pymobiledevice3` (via `pipx`), and build the Darwin SDK:

   ```sh
   xcross setup
   xcross sdk install ~/Downloads/Xcode.xip   # once, takes a while
   ```

   `xcross setup` detects `apt`, `dnf`, or `pacman` (and asks which to use when the answer is ambiguous). It also installs `usbmuxd`, `usbutils`, and `libimobiledevice` for USB device access and diagnostics. `pymobiledevice3` goes into its own `pipx` venv, and `pipx ensurepath` puts `~/.local/bin` on your `PATH` - open a new shell for that to take effect.

   The SDK is tied to the Swift you had active here. If you later switch Swift versions, re-run `xcross sdk install`.

### Nix

Use the xcross development shell from your project's flake without cloning this
repository:

```nix
{
  inputs.xcross.url = "github:arxdeus/xcross";

  outputs = { nixpkgs, xcross, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      devShells.${system}.default = pkgs.mkShell {
        inputsFrom = [ xcross.devShells.${system}.default ];
      };
    };
}
```

Run `nix develop`, then use `xcross` normally. `aarch64-linux` is also
supported.

### Verifying a release

Every release archive is built by [`release.yml`](.github/workflows/release.yml) and signed with a [SLSA build provenance attestation](https://docs.github.com/actions/security-for-github-actions/using-artifact-attestations) that binds the archive's digest to the commit it was built from. The release job refuses to publish an artifact whose provenance does not match, so a bundle produced outside this repository can never reach the release page.

To check an archive yourself with the [`gh`](https://cli.github.com) CLI (`SHA256SUMS.txt` is published alongside the archives for plain integrity checks):

```sh
gh attestation verify xcross-linux-x64.tar.gz \
  --repo arxdeus/xcross \
  --signer-workflow arxdeus/xcross/.github/workflows/release.yml \
  --source-digest <commit-sha-from-the-release-notes>
```

### Updating

```sh
xcross --version          # what you are running
xcross update --check     # what the latest release is
xcross update             # download, verify, and swap it in
```

`xcross update` downloads the release archive for your platform, verifies it against the release's `SHA256SUMS.txt` before touching anything, and replaces the installed `bin/` and `lib/` files in place. A checksum that does not match aborts the update, and a failure part-way through restores the previous version. On Linux a system-wide install (`/usr/local/...`) prompts for `sudo`; on Windows a machine-wide install needs an Administrator terminal.

Other commands print a one-line hint when a newer release exists. That hint comes from a cache refreshed at most once a day, so it costs no time on the command you actually ran. Set `XCROSS_NO_UPDATE_CHECK=1` to turn it off; it is already off in CI, for non-interactive output, and for builds from source.

Use `xcross update --ref <ref>` to target a specific git ref. `<ref>` may be a released tag, a branch name, a full 40-character commit SHA, or a full ref such as `refs/tags/1.2.0` or `refs/heads/main`.

```sh
xcross update --ref 1.2.0                    # install verified assets from release tag 1.2.0
xcross update --ref main                     # build and install from the main branch tip
xcross update --ref 85e325fb487cc816c9839bf64439f65771c92f62  # build and install from a specific commit
xcross update --check --ref refs/heads/main  # report ref kind + commit, do not install
```

If a tag and branch share the same short name, the exact tag wins. Tag refs install the existing verified release assets for that version. Branch and commit refs clone the official `arxdeus/xcross` repository into temporary storage, fetch the exact commit, run local `dart pub get` and the shared `tool/build_xcross.dart` wrapper, install the resulting bundle with the same atomic swap and rollback path as release updates, and delete the temporary checkout whether the install succeeds or fails.

A source-ref install reports the normalized ref, for example `xcross main (unreleased build)`. Running `xcross update` from any unreleased build always returns to the latest official release.

Source refs require both `git` and `dart` on `PATH`. `xcross update --check --ref <ref>` resolves the ref first, then reports its kind and commit without installing anything. Use `--force` to reinstall the current release when you are updating without `--ref`.

## Authentication

xcross talks to Apple's Developer Services directly. Two options:

|  | Apple ID | App Store Connect API key |
| --- | --- | --- |
| Apple account needed | free account works | paid Developer Program |
| Interactive login | password + 2FA once | none, good for CI |
| Protocol | the one Xcode speaks, undocumented | official and documented |
| Build, sign, install, run | yes | yes |
| **App Groups** (share extensions) | **created and attached automatically** | cannot be created; use one you attached yourself, see [app extensions](docs/app-extensions.md#app-store-connect-api-keys) |

The App Groups row is the only functional difference, and it is Apple's doing
rather than xcross's: the public App Store Connect API has no App Groups
resource at all, while the older protocol Xcode itself uses does. It only
matters if your app ships a share or action extension that hands data back to
the app.

### Apple ID (free account works)

```sh
xcross auth --apple-id you@example.com
```

The command prompts for your password and 2FA code, then stores **only** the resulting Developer Services session - never your password.

> [!IMPORTANT]
> Use a separate Apple account, not your main one. xcross signs in through a non-standard path for non-macOS systems, and Apple may treat that as unusual activity. Nothing has gone wrong in months of use before the public release, but the risk is not zero - and if an account does get flagged, you do not want it to be the one holding your purchases, iCloud data, and devices. Creating a throwaway Apple ID for xcross takes a minute and works fine, since a free account is all you need.

Machine attestation uses Android ADI libraries (`libCoreADI.so`, `libstoreservicescore.so`):

- **Windows x64 / Linux x86_64** - downloaded automatically from the Apple Music APK into `%APPDATA%\xcross\adi-libs` (Windows) or `~/.config/xcross/adi-libs` (Linux) on first use.
- **Other architectures** - extract the matching APK slice yourself and pass `--adi-library-dir`.

### App Store Connect API key

```sh
xcross auth --issuer-id <uuid> --key-id <id> --private-key /path/to/AuthKey.p8
```

Non-interactive, so this is the one to use on CI. It provisions everything
except App Groups, which Apple's public API cannot manage at all. If your app
has a share extension, attach the group to your App IDs once (in Xcode or at
developer.apple.com) and point xcross at it:

```sh
XCROSS_APP_GROUP=group.com.example.Shared xcross flutter run
```

See [iOS app extensions](docs/app-extensions.md) for the details.

### Sign out

```sh
xcross auth clear
```

Deletes the saved App Store Connect key, the Apple ID session and its machine attestation state, and every certificate, private key, and provisioning profile xcross minted. The downloaded ADI libraries stay - they are architecture-specific binaries that identify no account.

## Quick start

```sh
# 1. One-time machine setup (see Installation above)
#    Swift must already be installed: xcross does not install it, and both
#    commands below refuse to run without it.
xcross setup
xcross sdk install ~/Downloads/Xcode.xip
xcross auth --apple-id you@example.com

# 2. Check build and run requirements without changing anything
cd my_flutter_app
xcross doctor

# 3. Once per device reconnect: mount DDI + start the RSD tunnel
#    (Administrator PowerShell on Windows; root on Linux)
xcross tunnel

# 4. Build, sign, install, launch, hot-reload
xcross flutter run

# 5. Optional: wire up your IDE
xcross ide vscode      # or: xcross ide idea
```

While the app is running:

| Key | Action |
|---|---|
| `r` | Hot reload |
| `R` | Hot restart |
| `q` / `Ctrl-C` / `Ctrl-D` | Quit |

With multiple iPhones connected, an interactive terminal shows a numbered device picker; pass `-u <UDID>` for CI or piped runs.

`xcross doctor` is read-only: it checks Linux or Windows host tools, the Darwin SDK, the current Flutter or Compose project, authentication, device tooling, and connected iOS versions without building, installing, or launching. Missing project or device context is a warning; failed requirements return a nonzero exit code.

## Run over Wi-Fi

Prepare the wireless pairing and RSD tunnel first:

```sh
xcross tunnel --wifi
```

The command automatically follows this order:

1. **USB connected:** pairs RemotePairing through the iPhone's trusted lockdown connection, enables Wi-Fi connections, opens the RSD tunnel, and mounts the Developer Disk Image. Unplug USB when it reports that the device is ready.
2. **No USB, saved pairing available:** tries to reconnect to the saved wireless device.
3. **Saved device does not reconnect:** starts a fresh, suffixed `remote pair-host` advertisement so iOS does not reuse the stale entry.
4. **No USB and no saved pairing:** starts `remote pair-host` immediately.

Then run the app over Wi-Fi:

```sh
xcross flutter run --wifi
```

Device-initiated pairing without USB requires **iOS 27 or later**. When prompted, open **Settings > Privacy and Security > Developer Mode > Paired Devices > Other Devices**, tap the exact `xcross-...` name printed in the terminal, and enter the six-digit code. On iOS 17 through 26, connect USB once and run `xcross tunnel --wifi` to create the wireless pairing through lockdown.

Keep the iPhone unlocked and on the same local subnet during setup. Wireless discovery uses mDNS on UDP port 5353, so guest-network isolation, VPN routing, firewalls, NAT, and unbridged VM or WSL networking can block it. For diagnostics, put the verbose flag at the end:

```sh
xcross tunnel --wifi -v
```

Without an explicit transport flag, `xcross flutter run` prefers a locally attached USB device and falls back to Wi-Fi when no USB device is available. Use `--wifi` or `--usb` to force one transport.

See the full [Wi-Fi setup and troubleshooting guide](https://xcross.sh/docs/wireless).

## Command reference

| Command | Description |
|---|---|
| `xcross setup` | Install host dependencies (apt/dnf/pacman packages, `pipx`, `pymobiledevice3`). Requires Swift on `PATH`; `--no-swift-check` skips that to bootstrap Swift's own dependencies |
| `xcross sdk install <Xcode.xip>` | Extract a private Darwin Swift SDK from an Xcode archive, patched against the Swift toolchain currently on `PATH` |
| `xcross auth` | Save Apple ID or App Store Connect credentials |
| `xcross auth clear` | Delete saved credentials, sessions, and signing material |
| `xcross doctor` | Read-only check of host, SDK, project, authentication, and device requirements for build and run |
| `xcross tunnel` | Mount the Developer Disk Image + start the iOS 17+ RSD tunnel over USB |
| `xcross tunnel --wifi` | Prepare wireless pairing, reconnect or advertise pair-host, mount DDI, and open the Wi-Fi RSD tunnel |
| `xcross flutter run` | Build → sign → install → launch → hot reload |
| `xcross compose setup` | Install Kotlin/Compose iOS cross-build helpers |
| `xcross compose build` | Build a KMP iOS framework or `.app` from the current Gradle project |
| `xcross compose run -d <device>` | Build, sign, install, and launch a runnable KMP iOS app |
| `xcross compose run --watch` | Same, plus `r` to rebuild + reinstall + relaunch (Compose has no in-place reload) |
| `xcross flutter dap` | Run the Debug Adapter Protocol server (used by IDEs) |
| `xcross ide vscode` | Upsert `.vscode/*` for Run & Debug / Hot Reload |
| `xcross ide idea` | Write a JetBrains DAP run configuration (needs LSP4IJ) |
| `xcross update` | Update xcross to the latest release, verified against its checksums |
| `xcross completion` | Print a shell-completion script |

<details>
<summary><b><code>xcross flutter run</code> options</b></summary>

```text
-t, --target <path>          entrypoint (default: lib/main.dart)
-D, --dart-define k=v        repeatable
    --dart-define-from-file  .json / .env, repeatable
    --[no-]pub               run flutter pub get first (default: on)
    --build-name             CFBundleShortVersionString
    --build-number           CFBundleVersion
    --flavor                 flavor entrypoint selection
-i, --ipa                    package an .ipa instead of an .app
-d, --device-id              device id or name
-u, --udid                   device UDID; wins if both selectors are set
    --usb / --wifi           search USB-attached or wireless devices only
    --device-connection      attached | wireless | both
    --route
-a, --dart-entrypoint-args   repeatable
-v, --verbose
```
</details>

## Compose Multiplatform

`xcross compose` builds Kotlin Multiplatform iOS targets on Windows x64 and Linux x64 using the same private Darwin SDK, Swift, LLVM, and `xcross auth` signing flow as Flutter. Linux arm64 can run the CLI, but Compose iOS builds are limited by missing upstream Kotlin/Native host artifacts.

```sh
xcross setup
xcross sdk install /path/to/Xcode.xip
xcross compose setup
cd examples/compose_app        # or examples/kmp_swift_app
xcross compose build
xcross compose run -d <device>
```

Projects with a Kotlin `ComposeUIViewController` entry or a SwiftUI `@main` host produce an `.app`. Framework-only KMP modules still build the iOS framework, but `xcross compose run` and `--ipa` are unavailable until the project has a runnable app entry. Physical-device launch requires iOS 17 or later.

Compose launches use native attached debugging to supervise the process after install. There is no Kotlin source DAP yet.

Compose has no in-place hot reload, and cannot have one the way Flutter does: Kotlin/Native compiles the app ahead of time to a Mach-O binary, and JetBrains' own [Compose Hot Reload](https://kotlinlang.org/docs/multiplatform/compose-hot-reload.html) works only on a JVM target, through JetBrains Runtime class redefinition. What xcross offers instead is a fast restart loop:

```bash
xcross compose run --watch   # press r to rebuild + reinstall + relaunch, q to quit
```

`r` rebuilds only when a watched source (`.kt`, `.kts`, `.toml`, `.properties`) actually changed, then reinstalls and relaunches while keeping the device, RSD tunnel, and console session warm. An unchanged `r` leaves the running app alone.

Rebuilds are dominated by the Kotlin/Native compile (~133s of a ~147s cycle on the Compose sample, since it is a whole-program AOT compile). xcross fingerprints the framework's inputs and compiler flags, so a build whose inputs did not change skips `konanc` entirely: **~145s → ~12s** on the sample.

## Flutter plugins

Swift Package Manager iOS plugins work on both Windows and Linux. Their native code is compiled against the extracted Darwin SDK into `Frameworks/libFlutterPluginsGenerated.dylib` and registered by the generated runner.

Plugins that only ship a CocoaPods podspec are currently **skipped with a warning** - prefer plugin releases that include `ios/<package_name>/Package.swift`.

## App extensions

Share and action extensions are built, embedded under `PlugIns/`, signed with their own provisioning profiles and installed alongside the app, so plugins like [receive_sharing_intent](https://github.com/KasemJaffer/receive_sharing_intent) put your app in the iOS share sheet. No configuration needed.

Sharing data back to the app needs an App Group. Signed in with an Apple ID, xcross registers and attaches it for you. With an App Store Connect API key, Apple's public API cannot manage App Groups at all, so attach one yourself and pass `XCROSS_APP_GROUP`. See **[docs/app-extensions.md](docs/app-extensions.md)**.

## Bundle identity

The bundle id is read from the Flutter iOS project, using the same sources as Flutter's own tooling on non-macOS hosts:

1. A literal `CFBundleIdentifier` in `ios/Runner/Info.plist` (no `$(…)` variables), otherwise
2. the `PRODUCT_BUNDLE_IDENTIFIER` of the **application** target in `ios/Runner.xcodeproj/project.pbxproj`.

Step 2 reads the application target specifically: a project with app extensions declares several `PRODUCT_BUNDLE_IDENTIFIER`s, and the extension's often comes first in the file.

The packed `.app`'s `Info.plist` is always derived from `ios/Runner/Info.plist` when present. `$(MARKETING_VERSION)` and `$(CURRENT_PROJECT_VERSION)` are expanded from the application target's build settings, and embedded extensions inherit those versions, as iOS requires.

## IDE integration

### VS Code

```sh
xcross ide vscode
```

Writes the DAP shim and upserts an xcross launch entry + DAP settings into `.vscode/`. Press **F5** to build, sign, install, and launch. Hot Reload / Restart buttons drive the same `r`/`R` commands as the CLI, and DevTools attaches to the same VM Service connection.

- Works in VS Code forks with the Dart-Code extension installed.
- The xcross launch config sets `"env": { "XCROSS": "true" }`; other Flutter launch configs in the workspace keep working - sessions without that marker are handed to Flutter's own debug adapter.
- For multiple iPhones, set `"args": ["--udid", "<UDID>"]` on the xcross entry; re-running the command preserves those args.
- Existing `launch.json` / `settings.json` are merged in place (xcross keys upserted, everything else kept). A second run is a no-op when already current.
- Run the *installed* `xcross`; the generated DAP shim records that binary's path.

### JetBrains IDEA / Android Studio

```sh
xcross ide idea
```

Writes `.run/xcross_ios_device.run.xml` - a shared [LSP4IJ](https://plugins.jetbrains.com/plugin/23257-lsp4ij) Debug Adapter Protocol run configuration that starts `xcross flutter dap` over stdio.

- Install the LSP4IJ plugin, then Debug **xcross: iOS device** (don't use Flutter's Run button - it still calls `flutter run`).
- Breakpoints and stepping use the DAP/VM Service path; Restart maps to hot restart. Console `r`/`R` still work.
- An existing `.run/xcross_ios_device.run.xml` is never overwritten.

## FAQ

<details>
<summary><b>Why can't it build release/AOT?</b></summary>

Flutter's `gen_snapshot` for iOS AOT only runs on macOS hosts - Dart does not cross-compile an iOS AOT executable from Windows/Linux. Debug (JIT) builds don't need it, which is exactly what xcross produces. Release builds still need Flutter's macOS toolchain.
</details>

<details>
<summary><b>What does <code>xcross tunnel</code> do, and why does it need elevation?</b></summary>

It mounts the Developer Disk Image and starts the `pymobiledevice3` RSD tunnel - the encrypted QUIC/TUN tunnel iOS 17+ requires for developer services. Creating the TUN interface needs an Administrator PowerShell on Windows or root on Linux. Run it once per device reconnect.
</details>

<details>
<summary><b>How does <code>--wifi</code> (wireless run) work?</b></summary>

Wireless devices are discovered and reached through `pymobiledevice3 remote tunneld`, which finds the phone over mDNS (RemotePairing) and builds the RSD tunnel - usbmuxd is not involved, since the open-source usbmuxd on Linux and Windows never sees network devices. Requirements: iOS 17+, Developer Mode enabled, a one-time pairing with the host, and the phone unlocked on the same subnet (mDNS/UDP 5353 does not cross NAT - use bridged networking in a VM). `xcross tunnel --wifi` does the whole wireless setup with no cable: it advertises this host for device-initiated pairing (iOS 27+; the phone lists it as `xcross-<hostname>` under Settings > Privacy and Security > Developer Mode > Paired Devices > Other Devices and the 6-digit code prints in the terminal), builds the tunnel, and mounts the DDI through it. `xcross flutter run --wifi` also sets pairing up itself when needed (over the cable when USB is attached, via the same advertisement when not) and starts tunneld on demand; the tunnel needs root/Administrator for the TUN interface.
</details>

<details>
<summary><b>Does it support Compose Multiplatform?</b></summary>

Yes. Use `xcross compose setup`, then `xcross compose build` or `xcross compose run -d <device>` from a KMP project. Windows x64 and Linux x64 are supported; Linux arm64 is blocked by upstream Kotlin/Native host artifacts.
</details>

<details>
<summary><b>Is my Apple password stored anywhere?</b></summary>

No. `xcross auth` performs the login handshake locally and persists only the resulting Developer Services session token.
</details>

<details>
<summary><b>Why does an App Store Connect API key have fewer capabilities than an Apple ID?</b></summary>

Only for App Groups, and the cause is Apple's. The public App Store Connect API has no App Groups resource at all: its OpenAPI specification declares 966 paths and none of them mentions one, so a key cannot create a group or attach it to an App ID. The older protocol Xcode itself speaks does expose them, and that is what an Apple ID session uses.

So the documented, officially supported credential is the less capable one here, and the undocumented path is the complete one, with the stability caveat that implies.

It only matters if your app ships a share or action extension. A key still issues profiles that carry a group attached by other means, so attach one once in Xcode or at developer.apple.com and pass `XCROSS_APP_GROUP=group.your.id`. Everything else works identically. See [docs/app-extensions.md](docs/app-extensions.md).
</details>

<details>
<summary><b>Builds fail with "this SDK is not supported by the compiler"</b></summary>

`xcross sdk install` patches the Darwin SDK against the Swift toolchain that was selected at the time, and the SDK's Swift module interfaces can only be compiled by that toolchain. Changing the active Swift afterwards (`swiftly use`, `mise use`, or a distro upgrade) invalidates the pairing, and Swift then reports the mismatch once per importing source file:

```
error: failed to build module 'UIKit'; this SDK is not supported by the compiler
(the SDK is built with 'Apple Swift version 6.3.2 …', while this compiler is
'Swift version 6.3.2 (swift-6.3.2-RELEASE)'). Please select a toolchain which
matches the SDK.
```

xcross records the toolchain each SDK was installed with and stops the build with this explanation before Swift gets there. Either select the Swift toolchain the SDK was installed with, or reinstall the SDK against the current one:

```sh
xcross sdk install ~/Downloads/Xcode.xip
```

Note that the two versions in Swift's own message can look identical: the mismatch is between compiler *builds* (an Apple/vendor build vs a swift.org release), not just version numbers.
</details>

---

## Under the hood

xcross does not wrap or patch `flutter build ios` - that command simply refuses to run off-macOS. Instead, it re-implements the parts of Flutter's toolchain that matter for a debug device build, using the same engine artifacts, the same compilers, and the same device protocols the official tooling uses.

```text
xcross flutter run
   ├─ FlutterPacker
   │    ├─ IosEngineCache        download engine artifacts pinned to the SDK's engine hash
   │    ├─ FlutterDebugBundler   frontend_server → app.dill → App.framework (JIT)
   │    ├─ Native assets         Dart build hooks → arm64 frameworks + manifest
   │    ├─ SwiftPM plugins       swift build (Darwin SDK) → libFlutterPluginsGenerated.dylib
   │    ├─ RunnerShim            clang / ld64.lld → Runner Mach-O
   │    └─ assemble              Flutter.framework + Info.plist + flutter_assets → .app
   ├─ in-process codesign → install
   └─ CoreDeviceLauncher    RSD tunnel → launch suspended → gdb-remote attach
        └─ HotReloadController   DevFS + VM Service ⇄ frontend_server
```

### 1. Engine artifacts, straight from Flutter's CDN

`IosEngineCache` reads the engine revision from your Flutter SDK (the same hash `flutter` itself pins) and downloads exactly what Flutter's tool would cache: the prebuilt **`Flutter.xcframework`**, the debug **`vm_snapshot_data`** / **`isolate_snapshot_data`** JIT snapshots, the host **`frontend_server`**, and the Flutter **patched Dart SDK**. Your app therefore runs on the *identical* engine binary an Xcode build would embed - xcross never rebuilds or modifies the engine.

### 2. Kernel compilation with `frontend_server`

In debug mode Flutter apps are not compiled to machine code - the Dart VM runs **kernel bytecode** (JIT). `FlutterDebugBundler` drives the same `frontend_server` the Flutter tool uses (against the patched SDK, with your `--dart-define`s and flavor entrypoint) to produce `app.dill`, then lays out `App.framework` exactly like Flutter does:

- `flutter_assets/kernel_blob.bin` - the kernel program
- `flutter_assets/vm_snapshot_data`, `isolate_snapshot_data` - VM heap seeds
- `AssetManifest.bin/json`, `FontManifest.json`, fonts and assets - generated in Dart from your `pubspec.yaml`, replicating Flutter's asset bundling
- The `App.framework` *binary* in a debug build is only a stub - xcross compiles that stub with `clang` targeting `arm64-apple-ios` and writes the framework's `Info.plist` itself.

Because the app is pure JIT, no `gen_snapshot` is needed - which is precisely what makes macOS unnecessary (and why release/AOT is out of scope).

### 3. Native code without Xcode

- **Darwin SDK** - `darwin_sdk_kit` unpacks `Xcode.xip` with pure-Dart **xar**, **pbzx**, and **cpio** readers and assembles a Swift SDK bundle (iOS sysroot + frameworks) usable by upstream Swift/LLVM on Windows and Linux.
- **Runner** - the `Runner` executable (Flutter's `AppDelegate`/`main` shim) is compiled with `clang` and linked with `ld64.lld`, LLVM's Mach-O linker, against `Flutter.xcframework` from the SDK above.
- **Native assets** - Dart package build hooks run through Flutter's native-assets target with cross-platform Apple tool shims. Their output is thinned to arm64, embedded as frameworks, and recorded in `NativeAssetsManifest.json`.
- **Plugins** - SwiftPM iOS plugins are built with `swift build` against the same SDK into a single `libFlutterPluginsGenerated.dylib`, with a generated registrant mirroring Flutter's `GeneratedPluginRegistrant`. A Mach-O rewriter fixes install names and rpaths so the dylibs resolve inside the `.app` bundle.

### 4. Signing and device install, natively

`apple_developer_kit` implements Apple's **GrandSlam** login (with ADI machine attestation via the Android libraries), Developer Services provisioning (certificates, device registration, provisioning profiles), and **in-process Mach-O code signing** - no `codesign`, no `ldid`. Installation goes over the standard device protocols via `pymobiledevice3`.

### 5. iOS 17+ CoreDevice launch

iOS 17 replaced the old debug-launch path with **CoreDevice** over an encrypted **RSD tunnel**. `xcross tunnel` mounts the Developer Disk Image and brings the tunnel up; `CoreDeviceLauncher` then launches the app **suspended**, attaches a minimal **gdb-remote** client (the same protocol `debugserver` speaks) to resume and supervise the process, and port-forwards the **Dart VM Service** from the phone to localhost.

### 6. Hot reload: a faithful DevFS reimplementation

Hot reload is pure Flutter-internals territory, reimplemented protocol-for-protocol:

1. A long-lived `frontend_server` session (from `frontend_server_kit`) holds incremental compile state; a file watcher tracks your `lib/`.
2. On `r`, changed files are recompiled to an **incremental dill**, which is gzip-uploaded to the device via the VM Service's HTTP **DevFS** endpoint (`_createDevFS` + `PUT` - the same `org-dartlang-devfs://` filesystem Flutter's tool uses).
3. xcross calls `reloadSources` on the root isolate, then triggers `ext.flutter.reassemble` so the widget tree rebuilds.
4. `R` (hot restart) resets the compiler, uploads a full dill, and re-runs the app in each `FlutterView` via `_flutter.listViews` / run-in-view - matching Flutter's hot restart semantics.
5. The `frontend_server` is also registered as the VM Service's **expression compiler**, so debugger watch/evaluate works on-device.

### 7. IDE debugging via DAP

`xcross_dap` implements a **Debug Adapter Protocol** server that routes launch/attach, breakpoints, stepping, and hot-reload requests to the same VM Service connection. VS Code reaches it through a shim that intercepts launch configs marked with `"env": { "XCROSS": "true" }` (everything else falls through to Flutter's own adapter); JetBrains IDEs reach it through an LSP4IJ DAP run configuration.

## Credits

Thanks for maintainers for these repositories for their work, i took and adapt a lot from them:

- [xtool](https://github.com/xtool-org/xtool) - cross-platform Xcode replacement that pioneered building and deploying iOS apps with SwiftPM from Linux and Windows.
- [Provision](https://github.com/Dadoum/Provision) - reverse-engineered Apple ADI machine attestation and anisette provisioning; the foundation of xcross's Apple ID authentication approach.
- [anisette-v3-server](https://github.com/Dadoum/anisette-v3-server) - anisette data server powering Apple ID logins without Apple hardware.

## Support

xcross is free and open source. If it saves you a Mac, consider giving back:

- **Contribute** - pull requests are welcome, from typo fixes to new features.
- **Report** - found a bug or missing a feature? [Open an issue](https://github.com/arxdeus/xcross/issues).
- **Donate** - support ongoing development:

  [![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/E1E0I3G2D)

## License

[MIT](LICENSE)
