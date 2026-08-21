## 1.1.2

- Build, embed, sign and install iOS **app extensions** (share and action
  extensions). Extension targets are read from the Xcode project, compiled
  against the Darwin SDK, embedded at `<App>.app/PlugIns/<Name>.appex`, and
  each is given its own App ID and provisioning profile. This is what lets
  plugins such as `receive_sharing_intent` appear in the iOS share sheet.
  See `docs/app-extensions.md`. (#23)
- Resolve the bundle id from the **application** target rather than the first
  `PRODUCT_BUNDLE_IDENTIFIER` in `project.pbxproj`. A project with a share
  extension usually lists the extension's first, so xcross signed, installed
  and launched the extension instead of the app, showing a blank screen. (#23)
- Expand `$(MARKETING_VERSION)` and `$(CURRENT_PROJECT_VERSION)` from the
  application target's build settings. The default `ios/Runner/Info.plist`
  references both, so apps were shipping a literal `$(MARKETING_VERSION)` as
  their version string. Embedded extensions inherit the app's versions, which
  iOS requires them to match.
- Register App Groups declared by an app or its extensions, qualified per
  account (`group.XCR-<TEAM>.…`) because App Group ids are globally unique,
  and enable the App Groups capability on every App ID automatically, so the
  app and its extensions share a container with no manual step on
  developer.apple.com. Without the shared container a share extension can
  hand nothing back to the app, which is the whole point of
  `receive_sharing_intent`. (#23)
  App Groups are reached over the pre-JSON `QH65B2` protocol Xcode itself
  uses, because they have no modern API at all: Apple's App Store Connect
  OpenAPI specification declares 966 paths and none mentions App Groups.
- Take the App Group from the **issued provisioning profile** rather than
  assuming the request succeeded. Only the profile decides what iOS accepts,
  so this both avoids promising a container that does not exist and picks up a
  group attached by any other means. Signing with an ungranted group is what
  makes iOS refuse an install with `0xe8008015`.
- **App Groups with an App Store Connect API key.** Apple exposes no App
  Groups API to keys, so xcross cannot create the group, but it can now use
  one you attached yourself: add the group to your App IDs in Xcode or at
  developer.apple.com and pass `XCROSS_APP_GROUP=group.your.id`, which skips
  the per-account rewrite. Verified against a live key that no route exists to
  create one: `/v1/appGroups` 404s, the `APP_GROUPS` capability enables but
  cannot name a group (`settings[].key` accepts only `ICLOUD_VERSION`,
  `DATA_PROTECTION_PERMISSION_LEVEL`, `APPLE_ID_AUTH_APP_CONSENT`, on POST and
  PATCH alike), a `group.` identifier registers as an App ID but cannot be
  linked, and the developerservices2/portal hosts that do expose App Groups
  reject API keys under every audience tried.
- Warnings that describe an account-wide condition are printed once per run
  rather than once per App ID (an app with two extensions provisions three).

## 1.1.1

- Detect a Swift toolchain that no longer matches the installed Darwin SDK.
  `xcross sdk install` patches the SDK with the selected toolchain's clang
  headers, so switching Swift afterwards made every plugin build fail with
  "this SDK is not supported by the compiler" and no mention of the SDK.
  The toolchain is now recorded at install time and checked before building,
  with a message naming the cause and the command that fixes it.
- Require Swift on `PATH` before `xcross setup` and `xcross sdk install`,
  which previously failed only after a sudo prompt and a full package
  transaction, or after extracting tens of gigabytes. `xcross setup
  --no-swift-check` still bootstraps Swift's own build dependencies.
- Verify the Xcode archive before `xcross sdk install` removes the previous
  SDK, so a wrong path or a partial download no longer leaves the host with
  no SDK at all.
- Fail the Windows release job on failing tests, and fix the 7 Windows-only
  test bugs that gap had been hiding.

## 1.1.0

- Add Compose Multiplatform support: `xcross compose setup`, `xcross compose
  build`, and `xcross compose run` build, sign, install, and launch Kotlin
  Multiplatform iOS frameworks and `.app` bundles from Linux and Windows,
  with a `--watch` rebuild loop and fingerprinted builds that skip `konanc`
  when nothing changed.
- Provision and patch the Kotlin/Native toolchain for cross-host iOS builds:
  spoof Apple host checks, stage an Apple toolchain and the real compiler-rt
  archives, keep dependency resolution off the network, and disable
  Apple-only debug transparent stepping.
- Pass explicit `-arch` and `-platform_version` through the Swift runner
  link, and degrade a missing Windows `dsymutil` to a no-op.
- Build `sharedDarwinSource` Flutter plugins from their `darwin/` directory,
  and warn instead of silently dropping a plugin whose iOS manifest is
  missing.
- Generate and run the Dart plugin registrant, so federated plugins that
  register through `dartPluginClass` no longer fail at first use.

## 1.0.5

- Enhance Windows SwiftPM support and normalize staged plugin manifests.
- Synthesize fallback Clang/Swift modules for SwiftPM checkouts, including
  nested modules, module shims, and Swift interop headers for Objective-C
  and Swift consumers.
- Infer fallback module topology and linkage from sources, and preserve
  source fallback module names across rebuilds.
- Implement `#Preview` through a compiler plugin instead of patching plugin
  sources.
- Make Flutter plugin staging incremental, staging only iOS-reachable
  package entries, pruning entries the filter no longer stages, and skipping
  development-only trees and `pigeons/`.
- Keep binary files out of the sync transform, and preserve checkout symlink
  identity and materialized checkout placeholders.
- Forward symlinked headers and avoid a Clang module lock deadlock on
  Windows.
- Skip cross-host Swift interface verification.

## 1.0.4

- Resolve Flutter package configs from workspace roots.
- Pin the iOS SDK and sysroot for Flutter plugin linking, and expose Flutter
  headers to Objective-C plugins.
- Propagate the project's iOS deployment target through SwiftPM builds and
  generated app metadata.
- Normalize SwiftPM linker flags and stage normalized manifests for plugin
  builds.
- Skip generated imports for FFI-only Flutter plugins.

## 1.0.3

- Teach `xcross setup` to install host requirements on macOS via Homebrew
  and to verify the Windows toolchain more clearly.
- Find Homebrew LLVM/`lld` installs on Apple Silicon and Intel Macs when
  resolving Darwin SDK link tools.
- Recommend using a separate Apple account for auth in the README.

## 1.0.2

- Recover automatically when `tunneld` refuses to create an RSD tunnel:
  `xcross flutter run` now mounts the Developer Disk Image and starts a
  lockdown tunnel itself instead of stalling 60s and silently degrading to
  the userspace transport.
- Say why hot reload is unavailable, and answer `r`/`R` with that reason
  instead of ignoring the keypress.

## 1.0.1

- Add `xcross auth clear` to sign out: deletes the saved App Store Connect
  key, the Apple ID session and its machine attestation state, and every
  certificate, private key, and provisioning profile xcross minted.
- Reject unexpected positional arguments to `xcross auth` instead of silently
  starting an Apple ID login.
- Accept certificates and profiles Apple minted up to an hour ahead of a
  lagging host clock, and name both clocks in the error when it is worse.

## 1.0.0

- Build, sign, install, launch, and hot-reload Flutter iOS apps natively on
  Linux and Windows.
- Support Swift Package Manager Flutter plugins on both hosts.
- Apple ID/password login on Linux and Windows via Android ADI / Anisette, or
  App Store Connect API keys on either host.
- Remove the xtool runtime completely; xcross now owns Darwin SDK setup and
  uses the native device pipeline.
- Add `xcross --version`, stamped from the git tag at release build time.
- Add `xcross update` to self-update an installed xcross from the latest
  GitHub release, verified against the release's `SHA256SUMS.txt`.
- Print a cached, once-a-day "update available" hint on other commands;
  disable it with `XCROSS_NO_UPDATE_CHECK`.
