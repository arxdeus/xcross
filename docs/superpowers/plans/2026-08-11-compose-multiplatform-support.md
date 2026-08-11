# Compose Multiplatform Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-port CMP/KMP iOS build, setup, run, signing, installation, and attached native debugging onto latest `main` without restoring the obsolete xtool runtime.

**Architecture:** Add a focused Compose domain for project discovery, Kotlin/Native setup, framework creation, runner linking, and app assembly. Extract the platform-neutral device lifecycle from the Flutter command so Flutter and Compose share current provisioning, signing, installation, CoreDevice launch, GDB attachment, and session cleanup while supplying different launch profiles.

**Tech Stack:** Dart 3.10, package:args, build_cli, cli_kit, darwin_sdk_kit, dart_mobile_device, apple_developer_kit, archive, propertylistserialization, Kotlin/Native 2.2.x, Gradle, Swift, LLVM/ld64.lld.

## Global Constraints

- Support the xcross release hosts: Windows x64 and Linux x64. Linux arm64 must fail before downloading Kotlin/Native because JetBrains does not publish a Linux arm64 host compiler.
- Keep Flutter hot reload and Dart DAP behavior unchanged.
- Compose native debug means CoreDevice suspended launch, GDB-remote attach, resume, output streaming, and an attached process lifetime. Kotlin source DAP and hot reload are excluded.
- Reuse `DeviceBackend`, native Apple provisioning/signing, `CoreDeviceLauncher`, `IpaPackager`, `DarwinSdk`, `Log`, `ProcessRunner`, and `XcrossError`.
- Do not restore the xtool runtime, pre-iOS-17 launcher, Docker images, spike scripts, or old workflows.
- Build output lives under `<project>/build/xcross-ios/`.
- Every production behavior begins with a failing test and every task ends with a focused conventional commit.

## File Map

- `packages/xcross/lib/src/models/pack_result.dart`: shared `.app` or framework result.
- `packages/xcross/lib/src/device/core_device_launch_profile.dart`: Flutter versus native launch argument policy.
- `packages/xcross/lib/src/device/device_run_operation.dart`: shared resolve, version-gate, terminate, sign/install, launch sequence.
- `packages/xcross/lib/src/compose/`: Compose public barrel and domain.
- `packages/xcross/lib/src/compose/project/`: Gradle module discovery and xcconfig identity.
- `packages/xcross/lib/src/compose/toolchain/`: host descriptors, preflight, download/extraction, overlay, and compiler patching.
- `packages/xcross/lib/src/compose/build/`: Gradle KLIB, Kotlin/Native framework, runner, plist, assembly, and orchestration.
- `packages/xcross/lib/src/cli/compose/`: `build`, `run`, and `setup` commands.
- `packages/xcross/test/compose/`: unit fixtures and focused Compose tests.

---

### Task 1: Share the device run lifecycle

**Files:**
- Create: `packages/xcross/lib/src/models/pack_result.dart`
- Create: `packages/xcross/lib/src/device/core_device_launch_profile.dart`
- Create: `packages/xcross/lib/src/device/device_run_operation.dart`
- Modify: `packages/xcross/lib/src/flutter/build/flutter_pack_operation.dart`
- Modify: `packages/xcross/lib/src/flutter/flutter.dart`
- Modify: `packages/xcross/lib/src/device/core_device_launcher.dart`
- Modify: `packages/xcross/lib/src/cli/flutter/subcommands/flutter_run_command.dart`
- Test: `packages/xcross/test/device/core_device_launch_profile_test.dart`
- Test: `packages/xcross/test/device/device_run_operation_test.dart`

**Interfaces:**
- Produces: `PackResult({required String outputPath, required String bundleId, required PackOutputKind kind})`.
- Produces: `CoreDeviceLaunchProfile.flutter(arguments:, hotReload:)` and `CoreDeviceLaunchProfile.native(arguments:)`.
- Produces: `DeviceRunOperation.run({required PackResult pack, required String? selector, required DeviceSearchMode mode, required CoreDeviceLaunchProfile launchProfile})`.
- Consumes: existing `DeviceBackend`, `OsVersion.deviceOSMajorVersion`, `CoreDeviceLauncher.terminateIfRunning`, and `CoreDeviceLauncher.launch`.

- [ ] **Step 1: Write failing launch-profile tests**

```dart
void main() {
  test('native profile forwards only application arguments', () {
    final profile = CoreDeviceLaunchProfile.native(arguments: ['--demo']);
    expect(profile.argumentsForLaunch(isDap: false), ['--demo']);
    expect(profile.hotReload, isNull);
  });

  test('flutter profile adds VM and checked-mode arguments', () {
    const hotReload = HotReloadConfig(
      dart: '/flutter/bin/cache/dart-sdk/bin/dart',
      frontendServer: '/flutter/bin/cache/frontend_server.dart.snapshot',
      sdkRoot: '/flutter/bin/cache/artifacts/engine/common/flutter_patched_sdk',
      packageConfig: '/app/.dart_tool/package_config.json',
      entrypoint: '/app/lib/main.dart',
      projectRoot: '/app',
      outputDill: '/app/build/app.dill',
    );
    final profile = CoreDeviceLaunchProfile.flutter(
      arguments: const ['--route=/home'],
      hotReload: hotReload,
    );
    expect(profile.argumentsForLaunch(isDap: true), containsAll([
      '--vm-service-host=::',
      '--disable-service-auth-codes',
      '--start-paused',
      '--enable-checked-mode',
      '--verify-entry-points',
      '--route=/home',
    ]));
  });
}
```

- [ ] **Step 2: Run the profile test and verify RED**

Run: `dart test packages/xcross/test/device/core_device_launch_profile_test.dart`
Expected: compilation failure because `CoreDeviceLaunchProfile` does not exist.

- [ ] **Step 3: Implement the shared result and explicit launch profile**

```dart
enum PackOutputKind { app, framework }

final class PackResult {
  const PackResult({
    required this.outputPath,
    required this.bundleId,
    this.kind = PackOutputKind.app,
  });

  final String outputPath;
  final String bundleId;
  final PackOutputKind kind;

  String get appPath {
    if (kind != PackOutputKind.app) {
      throw StateError('PackResult is a framework, not an app');
    }
    return outputPath;
  }
}
```

```dart
final class CoreDeviceLaunchProfile {
  const CoreDeviceLaunchProfile.native({this.arguments = const []})
    : hotReload = null,
      _flutterRuntime = false;

  const CoreDeviceLaunchProfile.flutter({
    this.arguments = const [],
    required this.hotReload,
  }) : _flutterRuntime = true;

  final List<String> arguments;
  final HotReloadConfig? hotReload;
  final bool _flutterRuntime;

  List<String> argumentsForLaunch({required bool isDap}) => [
    if (_flutterRuntime && hotReload != null) ...[
      '--vm-service-host=::',
      '--vm-service-port=${TunnelConstants.vmServicePort}',
      '--disable-service-auth-codes',
      if (isDap) '--start-paused',
    ],
    if (_flutterRuntime) ...['--enable-checked-mode', '--verify-entry-points'],
    ...arguments,
  ];
}
```

Update `CoreDeviceLauncher.launch` to accept `required CoreDeviceLaunchProfile profile`, pass `profile.argumentsForLaunch(isDap: _isDap)` to suspended launch, and pass `profile.hotReload` to the existing hot-reload/session logic.

- [ ] **Step 4: Write the failing shared lifecycle test**

```dart
final events = <String>[];
final backend = FakeDeviceBackend(
  device: const Device(name: 'Phone', udid: 'U1', type: ConnectionType.usb),
  events: events,
);
final operation = DeviceRunOperation(
  backend: backend,
  osMajorVersion: (_) async => 17,
  terminate: ({required udid, required bundleId}) async {
    events.add('terminate:$udid:$bundleId');
  },
  launch: ({required udid, required bundleId, required profile}) async {
    events.add('launch:$udid:$bundleId:${profile.arguments.single}');
  },
);

await operation.run(
  pack: const PackResult(
    outputPath: '/build/App.app',
    bundleId: 'com.example.app',
  ),
  selector: null,
  mode: DeviceSearchMode.all,
  launchProfile: const CoreDeviceLaunchProfile.native(arguments: ['arg']),
);

expect(events, [
  'resolve',
  'terminate:U1:com.example.app',
  'install:/build/App.app:U1:com.example.app',
  'launch:U1:com.example.app:arg',
]);
```

Also test that iOS 16 throws before terminate/install and that `PackOutputKind.framework` is rejected before device discovery.

- [ ] **Step 5: Run the lifecycle test and verify RED**

Run: `dart test packages/xcross/test/device/device_run_operation_test.dart`
Expected: compilation failure because `DeviceRunOperation` does not exist.

- [ ] **Step 6: Implement `DeviceRunOperation` and migrate Flutter run**

```dart
typedef OsMajorVersion = Future<int?> Function(String udid);
typedef TerminateInstalledApp = Future<void> Function({
  required String udid,
  required String bundleId,
});
typedef LaunchInstalledApp = Future<void> Function({
  required String udid,
  required String bundleId,
  required CoreDeviceLaunchProfile profile,
});

final class DeviceRunOperation {
  DeviceRunOperation({
    required this.backend,
    OsMajorVersion? osMajorVersion,
    TerminateInstalledApp? terminate,
    LaunchInstalledApp? launch,
  }) : _osMajorVersion = osMajorVersion ?? OsVersion.deviceOSMajorVersion,
       _terminate = terminate ?? CoreDeviceLauncher.terminateIfRunning,
       _launch = launch ?? CoreDeviceLauncher.launch;

  static Future<DeviceRunOperation> resolve() async =>
      DeviceRunOperation(backend: await DeviceBackend.resolve());

  final DeviceBackend backend;
  final OsMajorVersion _osMajorVersion;
  final TerminateInstalledApp _terminate;
  final LaunchInstalledApp _launch;

  Future<Device> run({
    required PackResult pack,
    required String? selector,
    required DeviceSearchMode mode,
    required CoreDeviceLaunchProfile launchProfile,
  }) async {
    if (pack.kind != PackOutputKind.app) {
      throw XcrossError('A framework-only KMP build cannot be run on a device.');
    }
    final device = await backend.resolveDevice(selector: selector, mode: mode);
    final major = await _osMajorVersion(device.udid);
    if (major != null && major < 17) {
      throw XcrossError('Native device launching requires iOS 17 or later.');
    }
    await _terminate(udid: device.udid, bundleId: pack.bundleId);
    await backend.install(
      pack.appPath,
      udid: device.udid,
      mode: mode,
      bundleId: pack.bundleId,
    );
    await _launch(
      udid: device.udid,
      bundleId: pack.bundleId,
      profile: launchProfile,
    );
    return device;
  }
}
```

Replace Flutter command `_requireCoreDeviceSupport`, `_install`, and `_launch` with construction of the Flutter profile and one call to `DeviceRunOperation.run`.

- [ ] **Step 7: Verify Task 1**

Run: `dart test packages/xcross/test/device/core_device_launch_profile_test.dart packages/xcross/test/device/device_run_operation_test.dart packages/xcross/test/cli/flutter_command_args_test.dart`
Expected: all pass.

- [ ] **Step 8: Commit Task 1**

```bash
git add packages/xcross/lib/src/models packages/xcross/lib/src/device packages/xcross/lib/src/flutter packages/xcross/lib/src/cli/flutter packages/xcross/test/device packages/xcross/test/cli/flutter_command_args_test.dart
git commit -m "refactor(device): share app run lifecycle"
```

---

### Task 2: Detect KMP projects and resolve app identity

**Files:**
- Create: `packages/xcross/lib/src/compose/compose.dart`
- Create: `packages/xcross/lib/src/compose/models/compose_build_options.dart`
- Create: `packages/xcross/lib/src/compose/project/ios_app_config.dart`
- Create: `packages/xcross/lib/src/compose/project/kmp_project.dart`
- Test: `packages/xcross/test/compose/ios_app_config_test.dart`
- Test: `packages/xcross/test/compose/kmp_project_test.dart`

**Interfaces:**
- Produces: `enum ComposeConfiguration { debug, release }`.
- Produces: `ComposeBuildOptions({ComposeConfiguration configuration = ComposeConfiguration.debug, String? bundleId, String? appName, bool ipa = false})`.
- Produces: `IosAppConfig.parse(String)` and `IosAppConfig.load(String root)`.
- Produces: `KmpProject.detect(String root)` returning module path/name/base name, entry kind, Swift sources/imports, and identity defaults.

- [ ] **Step 1: Write failing xcconfig tests**

Test simple assignments, comments, `$(VAR)` expansion, missing version defaults, and a missing `iosApp/Configuration/Config.xcconfig` returning null. Assert:

```dart
final config = IosAppConfig.parse(r'''
TEAM_ID =
PRODUCT_NAME = KotlinProject
PRODUCT_BUNDLE_IDENTIFIER = org.example.KotlinProject$(TEAM_ID)
MARKETING_VERSION = 1.2
CURRENT_PROJECT_VERSION = 7
''');
expect(config.productName, 'KotlinProject');
expect(config.bundleId, 'org.example.KotlinProject');
expect(config.marketingVersion, '1.2');
expect(config.currentProjectVersion, '7');
```

- [ ] **Step 2: Verify xcconfig RED**

Run: `dart test packages/xcross/test/compose/ios_app_config_test.dart`
Expected: compilation failure because `IosAppConfig` does not exist.

- [ ] **Step 3: Implement xcconfig parsing**

Use `InfoPlist.parseXcconfig` semantics without importing the Flutter domain: ignore blank/comment lines, split at the first `=`, remove conditional key suffixes, recursively expand known `$(NAME)` tokens up to eight passes, replace unresolved tokens with an empty string, and default product/version values to `Runner`, `1.0`, and `1`.

- [ ] **Step 4: Write failing project detection tests**

Create temporary Gradle fixtures and assert:

```dart
final project = KmpProject.detect(root.path);
expect(project.moduleName, 'shared');
expect(project.baseName, 'Shared');
expect(project.entryKind, KmpEntryKind.runnableApp);
expect(project.entryClass, 'MainViewControllerKt');
expect(project.entrySelector, 'MainViewController');
```

Cover nested `include(":a:b")`, Swift `@main` discovery excluding Preview Content, framework-only modules, no iOS module, and two matching modules producing an ambiguity error. Add identity precedence tests: explicit CLI options, then xcconfig, then sanitized root-directory defaults.

- [ ] **Step 5: Verify project detection RED**

Run: `dart test packages/xcross/test/compose/kmp_project_test.dart`
Expected: compilation failure because `KmpProject` does not exist.

- [ ] **Step 6: Implement project models and detection**

```dart
enum KmpEntryKind { runnableApp, swiftApp, frameworkOnly }

final class KmpProject {
  const KmpProject({
    required this.root,
    required this.modulePath,
    required this.moduleName,
    required this.baseName,
    required this.entryKind,
    required this.bundleId,
    required this.appName,
    this.entryClass,
    this.entrySelector,
    this.swiftAppDir,
    this.swiftSources = const [],
    this.swiftImports = const {},
    this.iosConfig,
  });

  static KmpProject detect(
    String root, {
    String? bundleId,
    String? appName,
  }) => _KmpProjectDetector(
    root: root,
    bundleIdOverride: bundleId,
    appNameOverride: appName,
  ).detect();
}
```

Port the validated Gradle and source detection rules from `feat/cmp_support-legacy:lib/src/build/kmp_project.dart`, replacing xtool configuration with explicit options and xcconfig/default identity resolution. Keep module ambiguity an error.

- [ ] **Step 7: Verify Task 2**

Run: `dart test packages/xcross/test/compose/ios_app_config_test.dart packages/xcross/test/compose/kmp_project_test.dart`
Expected: all pass.

- [ ] **Step 8: Commit Task 2**

```bash
git add packages/xcross/lib/src/compose packages/xcross/test/compose
git commit -m "feat(cmp): detect kotlin multiplatform projects"
```

---

### Task 3: Port the Kotlin compiler bytecode patcher

**Files:**
- Create: `packages/xcross/lib/src/compose/toolchain/host_manager_patcher.dart`
- Create: `packages/xcross/test/compose/support/class_file_builder.dart`
- Create: `packages/xcross/test/compose/support/class_file_inspector.dart`
- Create: `packages/xcross/test/compose/support/fake_classes.dart`
- Test: `packages/xcross/test/compose/host_manager_patcher_test.dart`

**Interfaces:**
- Produces: `Uint8List patchHostManagerClassBytes(Uint8List bytes)`.
- Produces: `Uint8List? patchObjCExportClassBytes(Uint8List bytes)`.
- Produces: `bool patchKotlinNativeJar(String jarPath)`.

- [ ] **Step 1: Port the legacy patcher tests first**

Copy the behavior tests from `feat/cmp_support-legacy:test/host_manager_patcher_test.dart` and its three helpers into the new package paths. Update imports only. Preserve checks for JVM long/double constant-pool slots, method bytecode replacement, StackMapTable removal, ObjC export patching, marker insertion, duplicate-entry rejection, and idempotence.

- [ ] **Step 2: Verify patcher RED**

Run: `dart test packages/xcross/test/compose/host_manager_patcher_test.dart`
Expected: compilation failure because the patcher functions do not exist.

- [ ] **Step 3: Port and adapt the patcher implementation**

Port `feat/cmp_support-legacy:lib/src/build/host_manager_patcher.dart` into the Compose toolchain domain. Keep these public constants stable for tests and diagnostics:

```dart
const jarMarkerPath = 'META-INF/XCROSS_HOST_MANAGER_PATCHED';
const hostManagerClassEntry =
    'org/jetbrains/kotlin/konan/target/HostManager.class';
const objcExportClassEntry =
    'org/jetbrains/kotlin/backend/konan/objcexport/ObjCExportKt.class';
```

Use `ArchiveFile` replacement rather than shelling out to `jar`, preserve every unmodified entry byte-for-byte, and return `false` when the marker already exists.

- [ ] **Step 4: Verify Task 3**

Run: `dart test packages/xcross/test/compose/host_manager_patcher_test.dart`
Expected: all pass.

- [ ] **Step 5: Commit Task 3**

```bash
git add packages/xcross/lib/src/compose/toolchain/host_manager_patcher.dart packages/xcross/test/compose
git commit -m "feat(cmp): patch kotlin native host checks"
```

---

### Task 4: Resolve and provision the cross-platform Kotlin/Native toolchain

**Files:**
- Create: `packages/xcross/lib/src/compose/toolchain/compose_host.dart`
- Create: `packages/xcross/lib/src/compose/toolchain/compose_toolchain.dart`
- Create: `packages/xcross/lib/src/compose/toolchain/compose_toolchain_resolver.dart`
- Create: `packages/xcross/lib/src/compose/toolchain/compose_toolchain_installer.dart`
- Create: `packages/xcross/lib/src/compose/toolchain/archive_extractor.dart`
- Test: `packages/xcross/test/compose/compose_host_test.dart`
- Test: `packages/xcross/test/compose/compose_toolchain_test.dart`

**Interfaces:**
- Produces: `ComposeHost.linuxX64`, `ComposeHost.windowsX64`, and `ComposeHost.current()`.
- Produces: `ComposeToolchain` with host compiler, Java home, Gradle invocation, Konan cache, and Darwin linker/compiler paths.
- Produces: `ComposeToolchainResolver.resolve({required ComposeHost host, required Map<String, String> environment, required String projectRoot})`.
- Produces: `ComposeToolchainResolver.problems({required ComposeHost host, required Map<String, String> environment, required String projectRoot})`.
- Produces: `ComposeToolchainResolver.ensure({required ComposeHost host, required Map<String, String> environment, required String projectRoot, bool allowInstall = true, bool force = false})`.
- Produces: `ComposeSetupOptions.resolve({required Map<String, String> env, required String projectRoot, required ComposeHost host})`.
- Produces: `ComposeToolchainInstaller.install({required ComposeSetupOptions options, bool force = false})` using injected download, extraction, and process seams.

- [ ] **Step 1: Write failing host descriptor tests**

```dart
expect(
  ComposeHost.linuxX64.hostArtifact('2.2.20'),
  'kotlin-native-prebuilt-2.2.20-linux-x86_64.tar.gz',
);
expect(
  ComposeHost.windowsX64.hostArtifact('2.2.20'),
  'kotlin-native-prebuilt-2.2.20-windows-x86_64.zip',
);
expect(
  ComposeHost.windowsX64.konancExecutable('/kn'),
  p.join('/kn', 'bin', 'konanc.bat'),
);
```

Also assert the shared iOS overlay artifact is `kotlin-native-prebuilt-<version>-macos-x86_64.tar.gz` and Linux arm64 receives a precise unsupported-host error.

- [ ] **Step 2: Verify host descriptor RED**

Run: `dart test packages/xcross/test/compose/compose_host_test.dart`
Expected: compilation failure because `ComposeHost` does not exist.

- [ ] **Step 3: Implement host descriptors and archive extraction**

```dart
enum ComposeHostOs { linux, windows }

final class ComposeHost {
  const ComposeHost._(this.os, this.classifier, this.archiveExtension);
  static const linuxX64 = ComposeHost._(
    ComposeHostOs.linux,
    'linux-x86_64',
    'tar.gz',
  );
  static const windowsX64 = ComposeHost._(
    ComposeHostOs.windows,
    'windows-x86_64',
    'zip',
  );

  final ComposeHostOs os;
  final String classifier;
  final String archiveExtension;

  String hostArtifact(String version) =>
      'kotlin-native-prebuilt-$version-$classifier.$archiveExtension';
}
```

Implement ZIP and tar.gz extraction with `package:archive`, reject archive entries escaping the destination, restore executable bits on POSIX, and extract into a staging directory before moving the complete tree into `~/.konan`.

- [ ] **Step 4: Write failing resolver and installer tests**

Test version precedence (`KN_VERSION`, Gradle version catalog, Gradle properties, built-in default), search-root ordering, Windows `.bat` invocation through `cmd.exe /d /c`, Linux executable invocation, actionable missing JDK/Gradle/LLVM errors, cached fast path, and installation URLs. Use injected callbacks and assert no network/process call occurs on the cached path.

```dart
final options = ComposeSetupOptions.resolve(
  env: {'HOME': home.path},
  projectRoot: project.path,
  host: ComposeHost.windowsX64,
);
expect(options.version, '2.2.20');
expect(options.kotlinHome, p.join(home.path, '.konan',
  'kotlin-native-prebuilt-windows-x86_64-2.2.20'));
```

- [ ] **Step 5: Verify resolver RED**

Run: `dart test packages/xcross/test/compose/compose_toolchain_test.dart`
Expected: compilation failure because toolchain resolver types do not exist.

- [ ] **Step 6: Implement resolver, preflight, and rootless installer**

Use the Maven base URL:

```dart
const kotlinNativeMavenBase =
    'https://repo.maven.apache.org/maven2/org/jetbrains/kotlin/'
    'kotlin-native-prebuilt';
```

Installation sequence:

1. Require Windows x64 or Linux x64.
2. Resolve JDK 21+, Gradle wrapper/system Gradle, `swiftc`, Darwin-capable clang, and `ld64.lld` using `ProcessRunner.which` and `DarwinSdk` resolvers.
3. Download the host archive and macOS x64 archive for the detected project Kotlin version.
4. Extract the host archive into a staging directory.
5. Copy `konan/targets/ios_arm64` and `klib/platform/ios_arm64` from the macOS archive into the host tree.
6. Patch every `kotlin-native-compiler-embeddable.jar`.
7. Warm dependencies with a temporary hello-world host compile.
8. Atomically move the complete host tree into the user cache.
9. Re-run preflight and return a fully non-null `ComposeToolchain`.

Do not install system packages and do not invoke sudo.

- [ ] **Step 7: Verify Task 4**

Run: `dart test packages/xcross/test/compose/compose_host_test.dart packages/xcross/test/compose/compose_toolchain_test.dart`
Expected: all pass.

- [ ] **Step 8: Commit Task 4**

```bash
git add packages/xcross/lib/src/compose/toolchain packages/xcross/test/compose
git commit -m "feat(cmp): provision kotlin native toolchain"
```

---

### Task 5: Build the project KLIB and dependency list with Gradle

**Files:**
- Create: `packages/xcross/lib/src/compose/build/process_invocation.dart`
- Create: `packages/xcross/lib/src/compose/build/gradle_klib_builder.dart`
- Test: `packages/xcross/test/compose/gradle_klib_builder_test.dart`

**Interfaces:**
- Produces: `ProcessInvocation(executable:, arguments:)` for POSIX scripts and Windows batch files.
- Produces: `GradleKlibResult(moduleKlibPath:, dependencies:)`.
- Produces: `GradleKlibBuilder.build({required KmpProject project, required ComposeToolchain toolchain})`.

- [ ] **Step 1: Write failing Gradle builder tests**

Use an injected process runner that records calls and writes the dependency output file. Assert the first command is `:<module>:compileKotlinIosArm64`, the second is the generated `dumpIosDeps` task, nested module `:a:b` uses task path `:a:b:*` and leaf `b` in the init script, platform KLIBs under the Kotlin home are excluded, and directory-form `.klib` dependencies are retained.

```dart
expect(result.moduleKlibPath, p.join(
  module.path,
  'build', 'classes', 'kotlin', 'iosArm64', 'main', 'klib', 'shared',
));
expect(result.dependencies, [externalKlib.path]);
```

- [ ] **Step 2: Verify Gradle builder RED**

Run: `dart test packages/xcross/test/compose/gradle_klib_builder_test.dart`
Expected: compilation failure because `GradleKlibBuilder` does not exist.

- [ ] **Step 3: Implement process invocation and Gradle KLIB build**

Port Stage 0 from the legacy packer. Select `gradlew` on Linux, `gradlew.bat` through `cmd.exe /d /c` on Windows, and system `gradle` only when no wrapper exists. Run with:

```text
:<module>:compileKotlinIosArm64
-Pkotlin.native.enableKlibsCrossCompilation=true
--no-daemon
--console=plain
```

Generate the reflection-based `dumpIosDeps` init script, pass its output path through `XCROSS_DEPS_OUT`, use `--no-configuration-cache`, delete the temporary script/output in `finally`, and throw if the module KLIB or dependency output is absent.

- [ ] **Step 4: Verify Task 5**

Run: `dart test packages/xcross/test/compose/gradle_klib_builder_test.dart`
Expected: all pass.

- [ ] **Step 5: Commit Task 5**

```bash
git add packages/xcross/lib/src/compose/build packages/xcross/test/compose/gradle_klib_builder_test.dart
git commit -m "feat(cmp): compile ios klibs with gradle"
```

---

### Task 6: Build an iOS framework with Kotlin/Native

**Files:**
- Create: `packages/xcross/lib/src/compose/build/konan_configuration.dart`
- Create: `packages/xcross/lib/src/compose/build/kotlin_framework_builder.dart`
- Test: `packages/xcross/test/compose/konan_configuration_test.dart`
- Test: `packages/xcross/test/compose/kotlin_framework_builder_test.dart`

**Interfaces:**
- Consumes: `KmpProject`, `ComposeBuildOptions`, `ComposeToolchain`, and `GradleKlibResult`.
- Produces: `KonanConfiguration.prepare({required KmpProject project, required ComposeToolchain toolchain})` returning an isolated patched Kotlin home/configuration for the build.
- Produces: `KotlinFrameworkBuilder.build({required KmpProject project, required ComposeBuildOptions options, required ComposeToolchain toolchain, required GradleKlibResult klib})` returning `<baseName>.framework`.

- [ ] **Step 1: Write failing Konan configuration tests**

Assert configuration is written under `<project>/build/xcross-ios/toolchain/`, contains normalized forward-slash paths, points `targetSysRoot.ios_arm64` to `DarwinSdk.iPhoneOSSdk()`, points `linker.ios_arm64` to the resolved host `ld64.lld`, and never writes `/tmp/uni`, `/usr/bin/xcrun`, or `/usr/libexec/PlistBuddy`.

- [ ] **Step 2: Verify configuration RED**

Run: `dart test packages/xcross/test/compose/konan_configuration_test.dart`
Expected: compilation failure because `KonanConfiguration` does not exist.

- [ ] **Step 3: Implement isolated Konan configuration**

Copy only mutable compiler configuration/JAR files into the project build tree so global cached Kotlin distributions remain reusable and concurrent projects do not race. Patch compiler JARs there, write the iOS target/linker/toolchain overrides, and prepend generated host shims to PATH. On Windows create `.cmd` shims and invoke them through `cmd.exe`; on Linux create executable shell shims. Use direct configured tool paths rather than absolute Unix system locations.

- [ ] **Step 4: Write failing framework builder tests**

Use a fake process runner that creates the expected framework binary/header. Assert debug omits `-opt`, release includes `-opt`, every external KLIB becomes a `-library` pair, bundle ID is passed as `-Xbinary=bundleId=<resolved-bundle-id>`, output paths use `debugFramework` or `releaseFramework`, and a missing output binary throws `XcrossError`.

- [ ] **Step 5: Verify framework builder RED**

Run: `dart test packages/xcross/test/compose/kotlin_framework_builder_test.dart`
Expected: compilation failure because `KotlinFrameworkBuilder` does not exist.

- [ ] **Step 6: Implement the framework builder**

```dart
final class KotlinFrameworkBuilder {
  Future<String> build({
    required KmpProject project,
    required ComposeBuildOptions options,
    required ComposeToolchain toolchain,
    required GradleKlibResult klib,
  }) async {
    final args = buildKonancArguments(
      project: project,
      options: options,
      klib: klib,
    );
    final invocation = toolchain.host.scriptInvocation(
      toolchain.konanc,
      args,
    );
    await runChecked(invocation, environment: toolchain.environment);
    final framework = expectedFramework(project, options.configuration);
    if (!File(p.join(framework, project.baseName)).existsSync()) {
      throw XcrossError('Kotlin/Native did not produce ${project.baseName}.framework.');
    }
    return framework;
  }
}
```

Invoke `konanc` or `konanc.bat` with target `ios_arm64`, product `framework`, `-Xinclude=<module klib>`, `-Xbinary=bundleId=<id>`, one `-library` per dependency, `-opt` only for release, and the prepared environment/configuration. Copy the final framework to `build/xcross-ios/<BaseName>.framework` for framework-only output.

- [ ] **Step 7: Verify Task 6**

Run: `dart test packages/xcross/test/compose/konan_configuration_test.dart packages/xcross/test/compose/kotlin_framework_builder_test.dart`
Expected: all pass.

- [ ] **Step 8: Commit Task 6**

```bash
git add packages/xcross/lib/src/compose/build packages/xcross/test/compose
git commit -m "feat(cmp): build kotlin native ios frameworks"
```

---

### Task 7: Link native runners and assemble installable app bundles

**Files:**
- Create: `packages/xcross/lib/src/compose/build/objc_runner_builder.dart`
- Create: `packages/xcross/lib/src/compose/build/swift_runner_builder.dart`
- Create: `packages/xcross/lib/src/compose/build/compose_info_plist.dart`
- Create: `packages/xcross/lib/src/compose/build/compose_app_assembler.dart`
- Test: `packages/xcross/test/compose/runner_builder_test.dart`
- Test: `packages/xcross/test/compose/compose_info_plist_test.dart`
- Test: `packages/xcross/test/compose/compose_app_assembler_test.dart`

**Interfaces:**
- Produces: `ObjcRunnerBuilder.build({required KmpProject project, required String frameworkPath, required ComposeToolchain toolchain})` for Kotlin UIKit entry points.
- Produces: `SwiftRunnerBuilder.build({required KmpProject project, required String frameworkPath, required ComposeToolchain toolchain})` for Swift `@main` hosts.
- Produces: `ComposeInfoPlist.build({required KmpProject project, Map<String, Object?> extras = const {}})`.
- Produces: `ComposeAppAssembler.assemble({required KmpProject project, required String runnerPath, required String frameworkPath})` returning an `.app` path.

- [ ] **Step 1: Write failing runner argument tests**

Assert the ObjC source imports UIKit and `<BaseName>/<BaseName>.h`, calls `UIApplicationMain`, and invokes the detected Kotlin selector. Assert clang targets `arm64-apple-ios15.0`, uses the current iPhoneOS SDK, framework search path, Darwin-capable clang, resolved `ld64.lld`, and `@executable_path/Frameworks` rpath. Assert Swift compilation includes `-parse-as-library`, `-resource-dir`, all detected Swift sources, framework search path, and resolved linker.

- [ ] **Step 2: Verify runner builder RED**

Run: `dart test packages/xcross/test/compose/runner_builder_test.dart`
Expected: compilation failure because runner builders do not exist.

- [ ] **Step 3: Implement ObjC and Swift runner builders**

Port legacy Stage 8 behavior, but resolve tools exclusively through `ComposeToolchain` and `DarwinSdk`. Do not call `file`; validate Mach-O output with the repository's existing binary readers or at minimum check the `0xfeedfacf`/`0xcffaedfe` 64-bit Mach-O magic and non-empty output.

- [ ] **Step 4: Write failing plist and assembly tests**

```dart
final xml = ComposeInfoPlist.build(
  bundleId: 'com.example.app',
  appName: 'Demo',
  marketingVersion: '2.0',
  buildVersion: '8',
  extras: {'CADisableMinimumFrameDurationOnPhone': true},
);
expect(xml, contains('<key>CFBundleExecutable</key>'));
expect(xml, contains('<string>Runner</string>'));
expect(xml, contains('<key>DTPlatformName</key>'));
expect(xml, contains('<key>CADisableMinimumFrameDurationOnPhone</key>'));
```

Assembly must create `Runner`, `Info.plist`, and `Frameworks/<BaseName>.framework`, set executable permissions on POSIX, and reject a missing runner/framework.

- [ ] **Step 5: Verify plist and assembly RED**

Run: `dart test packages/xcross/test/compose/compose_info_plist_test.dart packages/xcross/test/compose/compose_app_assembler_test.dart`
Expected: compilation failure because plist/assembler classes do not exist.

- [ ] **Step 6: Implement plist and app assembly**

Use `propertylistserialization` to parse a project partial plist and serialize the final XML. Required values always override partial values: executable `Runner`, resolved bundle ID/name/version, package type `APPL`, iPhoneOS platform, minimum iOS 15, arm64 capability, device family, launch screen, and the same `DTPlatform*`/SDK keys used by current Flutter bundles. Preserve safe extra scalar/array/dictionary keys from the project plist.

Assemble into `build/xcross-ios/<AppName>.app`, recursively copy the framework without symlinks, make binaries executable on POSIX, and return the app path.

- [ ] **Step 7: Verify Task 7**

Run: `dart test packages/xcross/test/compose/runner_builder_test.dart packages/xcross/test/compose/compose_info_plist_test.dart packages/xcross/test/compose/compose_app_assembler_test.dart`
Expected: all pass.

- [ ] **Step 8: Commit Task 7**

```bash
git add packages/xcross/lib/src/compose/build packages/xcross/test/compose
git commit -m "feat(cmp): assemble native ios app bundles"
```

---

### Task 8: Orchestrate Compose packing and expose CLI commands

**Files:**
- Create: `packages/xcross/lib/src/compose/build/compose_pack_operation.dart`
- Create: `packages/xcross/lib/src/compose/build/compose_packer.dart`
- Create: `packages/xcross/lib/src/cli/compose/compose_command.dart`
- Create: `packages/xcross/lib/src/cli/compose/compose_build_command.dart`
- Create: `packages/xcross/lib/src/cli/compose/compose_run_command.dart`
- Create: `packages/xcross/lib/src/cli/compose/compose_setup_command.dart`
- Generate: `packages/xcross/lib/src/cli/compose/*.g.dart`
- Modify: `packages/xcross/lib/src/cli/runner.dart`
- Test: `packages/xcross/test/compose/compose_pack_operation_test.dart`
- Test: `packages/xcross/test/cli/compose_command_args_test.dart`

**Interfaces:**
- Produces: `ComposePackOperation.pack(options:, requireRunnableApp:)` returning `PackResult`.
- Produces: CLI commands `xcross compose build`, `xcross compose run`, and `xcross compose setup`.
- Consumes: all prior Compose builders and the shared device run lifecycle.

- [ ] **Step 1: Write failing orchestration tests**

Inject builder functions and assert order: detect, ensure toolchain, Gradle KLIB, framework, runner, assemble. Assert framework-only returns `PackOutputKind.framework`, framework-only run/IPA fails before toolchain/device work, and stale output is deleted before a build.

- [ ] **Step 2: Verify orchestration RED**

Run: `dart test packages/xcross/test/compose/compose_pack_operation_test.dart`
Expected: compilation failure because `ComposePackOperation` does not exist.

- [ ] **Step 3: Implement pack orchestration**

```dart
abstract final class ComposePackOperation {
  static Future<PackResult> pack({
    required ComposeBuildOptions options,
    bool requireRunnableApp = false,
  }) async {
    final project = KmpProject.detect(
      Directory.current.path,
      bundleId: options.bundleId,
      appName: options.appName,
    );
    if (project.entryKind == KmpEntryKind.frameworkOnly &&
        (requireRunnableApp || options.ipa)) {
      throw XcrossError('This KMP project produces a framework only.');
    }
    return ComposePacker(project: project, options: options).pack();
  }
}
```

`ComposePacker.pack` resolves/ensures toolchains once, runs the builders, returns framework output immediately for framework-only projects, selects ObjC versus Swift runner by entry kind, and assembles an app.

- [ ] **Step 4: Write failing CLI contract tests**

Assert `XcrossCli.buildRunner()` includes `compose`; `build` defaults to debug, IPA off, and accepts `--configuration`, `--bundle-id`, `--app-name`; `run` accepts Flutter-compatible `-d`, `-u`, `--usb`, `--wifi`, `--device-connection`, repeatable `-a/--app-argument`, and verbose; `setup` accepts `--check` and `--force`.

- [ ] **Step 5: Verify CLI RED**

Run: `dart test packages/xcross/test/cli/compose_command_args_test.dart`
Expected: compilation failure because Compose commands do not exist.

- [ ] **Step 6: Implement commands and generate parsers**

`compose build` calls `ComposePackOperation.pack`, optionally calls `IpaPackager.package` for app output, and logs the final path. `compose run` builds with `requireRunnableApp: true`, creates `CoreDeviceLaunchProfile.native(arguments: options.appArguments)`, and calls `DeviceRunOperation.resolve().run`. `compose setup --check` reports every preflight problem without downloading; normal setup provisions missing Compose-specific artifacts; `--force` refreshes the staged Kotlin home without deleting a valid cache until replacement succeeds.

Run: `cd packages/xcross && dart run build_runner build --delete-conflicting-outputs`
Expected: generated Compose command parser files appear with no conflicting outputs.

- [ ] **Step 7: Verify Task 8**

Run: `dart test packages/xcross/test/compose/compose_pack_operation_test.dart packages/xcross/test/cli/compose_command_args_test.dart packages/xcross/test/cli/flutter_command_args_test.dart`
Expected: all pass.

- [ ] **Step 8: Commit Task 8**

```bash
git add packages/xcross/lib/src/compose packages/xcross/lib/src/cli/compose packages/xcross/lib/src/cli/runner.dart packages/xcross/test/compose packages/xcross/test/cli
git commit -m "feat(cli): add compose multiplatform commands"
```

---

### Task 9: Add representative projects, documentation, and CI smoke builds

**Files:**
- Create: `examples/compose_app/` containing a minimal runnable Compose UIKit project.
- Create: `examples/kmp_swift_app/` containing a minimal Swift `@main` host and KMP framework.
- Modify: `README.md`
- Modify: `packages/xcross/pubspec.yaml`
- Modify: `.github/workflows/integration.yml`
- Test: `packages/xcross/test/release_packaging_test.dart`

**Interfaces:**
- Produces: documented end-user workflows and real build smoke inputs.
- Consumes: public CLI only, never private build classes.

- [ ] **Step 1: Add minimal example projects**

Trim the legacy examples to only files needed for iOS cross-build smoke tests: Gradle settings/version catalog/wrapper, KMP module build file, Kotlin sources, Swift sources/xcconfig/plist where applicable, and README. Exclude Android launcher assets and generated build output.

- [ ] **Step 2: Add command documentation**

Document requirements and commands:

```sh
xcross setup
xcross sdk install /path/to/Xcode.xip
xcross compose setup
xcross compose build
xcross compose run -d <device>
```

State Windows x64/Linux x64 support, Linux arm64 limitation, framework-only behavior, iOS 17+ requirement, native attached debugging, no Kotlin source DAP, no Compose hot reload, and signing through the same `xcross auth` flow as Flutter.

- [ ] **Step 3: Add CI smoke jobs**

Extend the existing private-SDK integration workflow with a Windows x64/Linux x64 matrix. Reuse its Swift/LLVM/Darwin SDK setup, install JDK 21, run `xcross compose setup`, build both examples, and assert these outputs:

```text
examples/compose_app/build/xcross-ios/ComposeApp.app/Runner
examples/kmp_swift_app/build/xcross-ios/KmpSwiftApp.app/Runner
```

Keep unit/analyze jobs credential-free. Do not add signing/device steps to CI.

- [ ] **Step 4: Verify docs and packaging**

Run: `dart test packages/xcross/test/release_packaging_test.dart`
Expected: pass with no missing runtime package files.

Run: `dart pub publish --dry-run` from `packages/xcross`
Expected: success with examples excluded from the package unless explicitly required.

- [ ] **Step 5: Commit Task 9**

```bash
git add examples README.md packages/xcross/pubspec.yaml .github/workflows/integration.yml packages/xcross/test/release_packaging_test.dart
git commit -m "docs(cmp): add compose workflows and smoke builds"
```

---

### Task 10: Full verification and integration review

**Files:**
- Modify only files needed to resolve observed verification failures.

**Interfaces:**
- Validates every acceptance criterion from the design spec.

- [ ] **Step 1: Format and regenerate**

Run: `dart format packages/xcross/lib packages/xcross/test`
Expected: no unformatted Dart files remain.

Run: `cd packages/xcross && dart run build_runner build --delete-conflicting-outputs`
Expected: generated files are current and `git diff --check` passes.

- [ ] **Step 2: Run authoritative Dart analysis**

Use the Dart MCP `analyze_files` operation for the workspace.
Expected: zero analyzer errors and warnings caused by this branch.

- [ ] **Step 3: Run all package tests**

```bash
dart test packages/xcross
dart test packages/cli_kit
dart test packages/apple_developer_kit
dart test packages/darwin_sdk_kit
dart test packages/dart_mobile_device
dart test packages/frontend_server_kit
```

Expected: all pass.

- [ ] **Step 4: Run package and CLI checks**

```bash
(cd packages/xcross && dart pub publish --dry-run)
(cd packages/xcross && dart build cli -t bin/xcross.dart)
packages/xcross/build/cli/*/bundle/bin/xcross compose --help
```

On Windows invoke `xcross.exe`. Expected: package validation succeeds, the release CLI builds, and help lists `build`, `run`, and `setup`.

- [ ] **Step 5: Run real Compose smoke builds on each supported host**

```bash
xcross compose setup --check
(cd examples/compose_app && xcross compose build)
(cd examples/kmp_swift_app && xcross compose build)
```

Expected: both `.app` bundles contain an arm64 Mach-O `Runner`, complete `Info.plist`, and nested Kotlin framework. If the current macOS coordinator cannot execute Windows/Linux-only smoke tests, require the corresponding GitHub Actions matrix to pass before completion.

- [ ] **Step 6: Request code review and fix findings**

Invoke the requesting-code-review skill. Review specifically for duplicated signing/device code, Flutter regressions, unsafe archive extraction, cache replacement safety, hardcoded Unix paths, Windows batch invocation, and framework-only guards. Resolve every confirmed issue and rerun the affected checks.

- [ ] **Step 7: Commit verification fixes**

```bash
git add -A
git commit -m "fix(cmp): resolve integration verification findings"
```

Skip this commit only when verification produced no file changes.
