# ARM64 support brief

Reviewed implementation: `2362e4f` (2026-10-03 UTC).

## Changes

- Added ARM64 host handling, Dart native build hooks, and architecture-specific ADI library loading and caches. Windows remains x64-only.
- Added Flutter and Compose ARM64 simulator builds: `xcross flutter build --target-platform simulator --debug` and `xcross compose build --target-platform simulator`.
- Added native Xcode.app SDK import, separate device/simulator outputs and caches, and headless macOS ARM64 CI with readiness markers, screenshots, crash checks and scoped cleanup.
- Fixed packaged xcrun delegation, native compiler SDK selection, Java shim discovery, Flutter workspace identity/migration, incomplete SDK publication and ADI POSIX compatibility.
- Removed plaintext Darwin SDK Actions caching. Trusted cross-host CI now uses `DARWIN_ARTIFACTBUNDLE_URL`.

## Verified

Independent Astra reviews and Sol fixes completed. Actual packaged CLI builds passed on macOS ARM64 for both device and simulator targets. Both apps rendered successfully during 20-second headless runs. Reciprocal target-switch builds preserved opposite-target binaries and all existing simulators remained unchanged.

Final suite: **1,911 passed, 18 skipped**. Also passed: 7 native bridge tests, 49 CI/helper/security tests and workflow linting.

## Limits and follow-up

- Native Linux ARM64 Compose remains upstream-blocked. Compose simulator compilation requires macOS.
- For Flutter 3.47.2, Linux ARM64 has Dart/engine prebuilts but no full SDK archive.
- Hosted CI, Linux/Windows runtime, physical-device execution and live authentication were not verified in this review.
- Simulator execution uses the headless helper, not a CLI simulator run mode.
- Remove any historical plaintext `xcross-darwin-*` Actions caches. They were not remotely deleted.
