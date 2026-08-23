## 1.2.2

- Phase release and update identity work so source-ref installs report injected normalized refs, tagged release archives report the release tag, and unreleased builds stay clearly marked until the next official update.
- Build Linux and Windows release artifacts through the shared compile-time identity wrapper, remove the hardcoded dev version fallback from stamped release automation, and keep unreleased installs returning to the latest official release.

## 1.2.1

- Replace the old tag-only update selector with `--ref`, so release tags still install verified release assets while branch and commit refs build from source before the same atomic install step.

## 1.2.0

- Add first-class wireless device support with `xcross tunnel --wifi` and
  `xcross flutter run --wifi`. xcross can bootstrap RemotePairing over a trusted
  USB connection, reconnect saved wireless pairings, or advertise the host for
  cable-free pairing on iOS 27+, then start a TCP RSD tunnel and mount the
  Developer Disk Image automatically. (#29)
- Discover wireless devices through `pymobiledevice3 tunneld`, route installs,
  app lookup, DDI mounting, and launches through the correct RSD transport, and
  surface actionable pairing, mDNS, Python, privilege, and tunnel diagnostics.
  (#29)
- Launch the exact account-qualified bundle id produced during signing and
  installation instead of guessing from installed apps. This avoids attaching
  to stale xcross builds or production/TestFlight builds with the same base
  bundle id, which could cause kernel-version errors or denied debugging. (#28)
- Complete App Groups support for share and action extensions. Xcode 16 synced
  folders and localized resources are handled correctly, Swift module names
  match extension principal classes, host and extensions use the same group and
  callback URL scheme, and Apple ID signing creates and attaches groups
  automatically. (#27)
- Treat the issued provisioning profile as the source of truth for App Group
  entitlements. App Store Connect API keys can use a group attached manually by
  passing `XCROSS_APP_GROUP`, while unsupported group creation no longer blocks
  an otherwise valid install. (#27)
- Retry Linux package installation after refreshing a stale APT index. (#29)

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
  account (`group.XCR-<TEAM>.…`) because App Group ids are globally unique.
  Enabling the capability on the App IDs is still a manual step on
  developer.apple.com; xcross reuses an existing group, so the next run picks
  it up.

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
