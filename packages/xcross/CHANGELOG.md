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
