# Compose Multiplatform Support Design

## Goal

Re-port the useful CMP/KMP work from `feat/cmp_support-legacy` onto latest `main`, using current xcross architecture instead of restoring obsolete xtool-era code. The result supports building and running Kotlin Multiplatform iOS apps from the Windows and Linux hosts supported by xcross.

## Scope

- Add `xcross compose build`, `xcross compose run`, and `xcross compose setup`.
- Support runnable Compose apps, Swift-hosted KMP apps, and framework-only KMP modules.
- Allow framework-only modules to build their framework, but reject `run` and IPA packaging with a precise error.
- Reuse current Darwin SDK, native signing, provisioning, install, CoreDevice launch/debug attachment, IPA packaging, logging, errors, and CLI conventions.
- Keep Flutter hot reload and Dart DAP behavior unchanged.
- CMP native debug means launching suspended, attaching through the existing CoreDevice/GDB remote session, resuming, streaming output, and keeping the process attached. Kotlin source-level DAP and hot reload are not part of this migration.
- Do not restore the old xtool runtime, duplicate signing stack, old pre-iOS-17 launcher, spike scripts, Docker images, or obsolete workflows.

## Architecture

### Compose domain

Create a focused `packages/xcross/lib/src/compose/` domain containing:

- Project discovery for Gradle modules, Kotlin/Native framework metadata, runnable entry points, Swift host sources, bundle identity, and version configuration.
- Toolchain preflight and rootless setup for the host Kotlin/Native distribution, iOS target overlay, Gradle, JDK, LLVM, and existing Darwin SDK.
- Host-manager patching required to let Kotlin/Native target iOS from non-macOS hosts.
- Build options and a pack operation returning the same app path and bundle identifier contract used by Flutter.
- Focused packing stages for Gradle/Kotlin compilation, framework assembly, Swift or generated host compilation, Mach-O linking, resources, and `Info.plist` creation.

The legacy implementation is reference material. Large files are split by responsibility and adapted to current package APIs, error types, logging, dependency versions, and filesystem layout.

### Shared application lifecycle

Move platform-neutral run behavior out of `FlutterRunCommand` into a shared operation with injected build-specific launch configuration:

1. Resolve a device using `DeviceBackend`.
2. Require iOS 17 or later.
3. Terminate a running instance through `CoreDeviceLauncher`.
4. Sign, provision, and install through `DeviceBackend.install`.
5. Launch and attach through `CoreDeviceLauncher`.

Flutter supplies its route arguments and optional hot-reload configuration. Compose supplies native application arguments, no Dart VM service, and no Flutter runtime flags. `CoreDeviceLauncher` receives an explicit launch profile so Flutter-only arguments are never added to CMP binaries.

### CLI

Register a `ComposeCommand` beside `FlutterCommand`:

- `compose build`: debug or release configuration, optional IPA output, unsigned by default.
- `compose run`: debug by default, device selectors matching Flutter, native signing/install, attached launch.
- `compose setup`: validate or provision Kotlin/Native prerequisites without replacing the existing global `xcross setup` and `xcross sdk` responsibilities.

Generated CLI argument files are regenerated using the repository's normal build process.

## Data flow

`compose build/run` discovers the project and resolves configuration, then validates the shared Darwin SDK and Compose-specific toolchain. The pack operation produces an unsigned `.app` or framework plus its original bundle identifier. `compose run` passes the `.app` to the shared device lifecycle, which qualifies the bundle identifier for the active Apple identity, rewrites `Info.plist`, signs nested frameworks and the app, installs it, resolves the signed identifier during launch, and keeps the native debug session attached.

## Errors

- Reject unsupported host architecture or missing host distribution before modifying caches.
- Report missing JDK, Gradle, Kotlin/Native, LLVM, or Darwin SDK with the exact command needed to fix it.
- Reject ambiguous module detection and unsupported project layouts instead of selecting silently.
- Reject framework-only `run` and IPA requests before device discovery.
- Preserve existing authentication, provisioning, signing, device, and iOS-version errors from shared components.
- Clean partial build outputs and temporary toolchain downloads without deleting valid caches.

## Testing

- Unit-test KMP module detection, entry-point detection, bundle/version configuration, host-manager patching, toolchain resolution, and output naming using temporary fixtures.
- Test CLI defaults, aliases, device-selection precedence, and framework-only guards.
- Test the shared device lifecycle with injected fakes, including operation ordering and Flutter/CMP launch-profile separation.
- Keep existing Flutter run, signing, DAP, and launcher tests passing unchanged.
- Add representative CMP and Swift-hosted KMP fixtures. CI performs analysis and unit tests on all hosts, plus toolchain-backed build smoke tests where the required artifacts are available.

## Migration strategy

The original branch remains preserved as `feat/cmp_support-legacy`. The new `feat/cmp_support` starts at latest `main`. Port production behavior in small tested commits, not by merging or cherry-picking the legacy feature commit. Examples and CI changes are added only when they validate the new implementation and follow current repository structure.

## Acceptance criteria

- `feat/cmp_support` is based on latest `main` with no legacy xtool dependency.
- `xcross compose build`, `run`, and `setup` are discoverable and documented.
- Runnable CMP and Swift-hosted KMP projects build an iOS app on supported Windows and Linux hosts.
- Framework-only KMP projects build a framework and fail clearly for run/IPA.
- Compose run uses current native signing, provisioning, install, CoreDevice launch, and attached debug session components.
- Flutter behavior and existing tests remain unchanged.
- Static analysis, unit tests, CLI packaging checks, and representative Compose build smoke tests pass.
