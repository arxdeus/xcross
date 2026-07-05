// Integrated port of setup-compose.sh — provisions a bare (non-Docker) Linux
// x86_64 host for `xcross compose` from inside the binary.
//
// Installs/downloads everything the ComposePacker pipeline needs (JDK 21, clang,
// lld, build tools, Kotlin/Native linux-x86_64 + the ios_arm64 overlay, and the
// warmed konanc native-dependency cache), then returns the resolved
// [ComposeToolchain] so the caller can thread it into ComposePacker within the
// same process (a Dart process cannot mutate its own Platform.environment).
//
// Mirrors Dockerfile.xcross-compose-amd64. apt installs need root; run the
// binary with sudo (or as root) for the first provisioning.
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xcross/src/build/compose_preflight.dart';
import 'package:xcross/src/constants/kotlin_native_constants.dart';
import 'package:xcross/src/util/download.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';
import 'package:xcross/src/util/process.dart';

// Matches `kotlin = "x.y.z"` under [versions] in libs.versions.toml.
final _kotlinTomlVersionPattern = RegExp(
  r'^\s*kotlin\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"',
  multiLine: true,
);

// Matches `kotlin.version=x.y.z` or `kotlinVersion=x.y.z` in gradle.properties.
final _kotlinPropsVersionPattern = RegExp(
  r'^\s*kotlin(?:\.version|Version)\s*=\s*([0-9]+\.[0-9]+\.[0-9]+)',
  multiLine: true,
);

/// Tunables for [provisionComposeToolchain], sourced from env with the same
/// knobs as setup-compose.sh (`KN_VERSION`, `KONAN_ROOT`).
///
/// Rootless by design: [konanRoot] defaults to a **user-writable** location
/// (`$HOME/.konan`) so no `sudo` is ever needed. `/opt/konan` (the Docker
/// image's location) is still honoured if you pass `KONAN_ROOT` explicitly.
class ComposeSetupOptions {
  ComposeSetupOptions({
    String? knVersion,
    String? konanRoot,
    String? home,
  })  : knVersion = (knVersion != null && knVersion.isNotEmpty)
            ? knVersion
            : KotlinNativeConstants.defaultVersion,
        konanRoot = _resolveKonanRoot(konanRoot, home);

  factory ComposeSetupOptions.fromEnv(Map<String, String> env) =>
      ComposeSetupOptions(
        knVersion: env['KN_VERSION'],
        konanRoot: env['KONAN_ROOT'],
        home: env['HOME'],
      );

  /// Resolve options, deriving the Kotlin/Native version to match the project.
  ///
  /// Version precedence: explicit `KN_VERSION` env → the project's Kotlin
  /// version (so our download/overlay matches what the KMP Gradle build already
  /// installs in `~/.konan`) → the built-in default.
  factory ComposeSetupOptions.resolve({
    required Map<String, String> env,
    String? projectRoot,
  }) {
    final envVer = env['KN_VERSION'];
    final projVer = (projectRoot != null && projectRoot.isNotEmpty)
        ? resolveProjectKnVersion(projectRoot)
        : null;
    return ComposeSetupOptions(
      knVersion:
          (envVer != null && envVer.isNotEmpty) ? envVer : (projVer ?? ''),
      konanRoot: env['KONAN_ROOT'],
      home: env['HOME'],
    );
  }

  /// User-writable K/N root: explicit `KONAN_ROOT` wins, else `$HOME/.konan`,
  /// else fall back to the shared default. Never requires root.
  static String _resolveKonanRoot(String? konanRoot, String? home) {
    if (konanRoot != null && konanRoot.isNotEmpty) return konanRoot;
    if (home != null && home.isNotEmpty) return p.join(home, '.konan');
    return KotlinNativeConstants.defaultKonanRoot;
  }

  final String knVersion;
  final String konanRoot;

  String get lxKn =>
      p.join(konanRoot, 'kotlin-native-prebuilt-linux-x86_64-$knVersion');

  String get mavenBase => '${KotlinNativeConstants.mavenBaseUrl}/$knVersion';
}

/// Best-effort detection of the project's Kotlin version — which pins the K/N
/// version the KMP Gradle build installs into `~/.konan`. Probes, in order,
/// `gradle/libs.versions.toml` then `gradle.properties`. Returns `null` if not
/// found (caller falls back to the built-in default).
String? resolveProjectKnVersion(String projectRoot) {
  // 1. gradle/libs.versions.toml  →  kotlin = "x.y.z"  (under [versions]).
  final toml = File(p.join(projectRoot, 'gradle', 'libs.versions.toml'));
  final tomlExists = toml.existsSync();
  if (tomlExists) {
    final m = _kotlinTomlVersionPattern.firstMatch(toml.readAsStringSync());
    if (m != null) return m.group(1);
  }
  // 2. gradle.properties  →  kotlin.version= / kotlinVersion=  x.y.z
  final props = File(p.join(projectRoot, 'gradle.properties'));
  final propsExists = props.existsSync();
  if (propsExists) {
    final m =
        _kotlinPropsVersionPattern.firstMatch(props.readAsStringSync());
    if (m != null) return m.group(1);
  }
  return null;
}

/// Validate the host, auto-provisioning the toolchain if anything is missing,
/// and return the resolved [ComposeToolchain] to thread into ComposePacker.
///
/// Fast path: if [collectComposeProblems] is already empty, no setup runs.
///
/// Controls:
///   - `XCROSS_SKIP_PREFLIGHT=1` — skip validation entirely (advanced/bring-your-own).
///   - `XCROSS_NO_AUTO_SETUP=1`  — validate but never auto-provision; fail with guidance.
///   - [allowSetup]              — programmatic override (defaults to true).
Future<ComposeToolchain> ensureComposeToolchain({
  bool allowSetup = true,
  String? projectRoot,
}) async {
  final env = Platform.environment;

  if (isTruthyEnv(env['XCROSS_SKIP_PREFLIGHT'])) {
    logWarn('compose preflight skipped (XCROSS_SKIP_PREFLIGHT set).');
    return resolveComposeToolchain(env);
  }

  final problems = collectComposeProblems(env);
  if (problems.isEmpty) {
    logStatus('[compose] toolchain ready — using cached setup.');
    return resolveComposeToolchain(env);
  }

  final autoSetup = allowSetup && !isTruthyEnv(env['XCROSS_NO_AUTO_SETUP']);
  if (!autoSetup) {
    throw XcrossError(formatComposeProblems(problems));
  }

  logStatus(
    '[compose] toolchain not ready (${problems.length} '
    'problem${problems.length == 1 ? '' : 's'}) — running integrated setup...',
  );
  for (final pr in problems) {
    logStatus('    · ${pr.what}: ${pr.detail}');
  }

  final provisioned =
      await provisionComposeToolchain(env: env, projectRoot: projectRoot);

  // Re-validate against the environment merged with what setup just resolved
  // (the new JAVA_HOME/XCROSS_LD64LLD/LX_KN aren't in our Platform.environment).
  final mergedEnv = <String, String>{...env, ...provisioned.toEnv()};
  final remaining = collectComposeProblems(mergedEnv);
  if (remaining.isNotEmpty) {
    throw XcrossError(
      'compose: setup ran but the toolchain is still not ready.\n\n'
      '${formatComposeProblems(remaining)}',
    );
  }

  logStatus('[compose] setup complete — toolchain ready.');
  return resolveComposeToolchain(mergedEnv);
}

/// Provision the compose-specific toolchain **without root** and return the
/// resolved [ComposeToolchain].
///
/// xcross never runs `sudo`/`apt`. The heavy, compose-specific bits — the
/// Kotlin/Native linux-x86_64 prebuilt, the ios_arm64 overlay, and the warmed
/// konan dependency cache — are downloaded into a user-writable dir
/// (`$HOME/.konan` by default). System packages (JDK 21, clang, lld) are
/// *prerequisites*: if any is missing this throws with an actionable message so
/// the user can install them with their own package manager. It does not
/// install them for you.
///
/// Steps:
///   0. preflight (Linux/x86_64)
///   1. verify JDK (JAVA_HOME or `java` on PATH)     — else actionable error
///   2. verify stock LLVM ld64.lld (runnable)         — else actionable error
///   3. download K/N linux-x86_64 prebuilt (user dir)
///   4. overlay ios_arm64 from the macos-x86_64 prebuilt
///   5. warm konanc's native deps (LLVM) via a throwaway host compile
Future<ComposeToolchain> provisionComposeToolchain({
  Map<String, String>? env,
  ComposeSetupOptions? options,
  String? projectRoot,
}) async {
  final environment = env ?? Platform.environment;
  final opts = options ??
      ComposeSetupOptions.resolve(
        env: environment,
        projectRoot: projectRoot ?? Directory.current.path,
      );
  _info('Kotlin/Native version: ${opts.knVersion} '
      '(from ${_knVersionSource(environment, projectRoot)}).');

  // ── 0. preflight ─────────────────────────────────────────────────────────
  if (!Platform.isLinux) {
    throw XcrossError(
        'compose setup: Linux only (got ${Platform.operatingSystem}).');
  }
  final arch = _uname('-m');
  if (arch != 'x86_64') {
    throw XcrossError(
      'compose setup: x86_64 only — Kotlin/Native konanc has no linux-aarch64 '
      'prebuilt (got $arch).',
    );
  }

  final javaHome = _ensureJdk(environment);
  final ld64lld = await _ensureLd64lld();
  await _ensureKotlinNative(opts);
  await _ensureIosOverlay(opts);
  await _warmDeps(opts, javaHome);

  _info('Done. Compose toolchain provisioned.');

  return ComposeToolchain(
    javaHome: javaHome,
    ld64lld: ld64lld,
    lxKn: opts.lxKn,
    konanDataDir: opts.konanRoot,
  );
}

// ── provisionComposeToolchain stage helpers ──────────────────────────────────

/// Stage 1: Verify JDK is available; returns JAVA_HOME path.
String _ensureJdk(Map<String, String> environment) {
  final javaHome = resolveComposeToolchain(environment).javaHome;
  if (javaHome == null || !isExecutableFile(p.join(javaHome, 'bin', 'java'))) {
    throw XcrossError(
      'compose setup: no JDK found (needed by konanc + Gradle).\n'
      'Install JDK 21 with your package manager, e.g.:\n'
      '    sudo apt-get install -y openjdk-21-jdk-headless\n'
      'then set JAVA_HOME (e.g. /usr/lib/jvm/java-21-openjdk-amd64). '
      'xcross does not install system packages.',
    );
  }
  _info('JAVA_HOME=$javaHome');
  return javaHome;
}

/// Stage 2: Verify stock LLVM ld64.lld is available and runnable; returns path.
Future<String> _ensureLd64lld() async {
  final ld64lld = findLd64Lld();
  if (ld64lld == null) {
    throw XcrossError(
      "compose setup: no stock LLVM ld64.lld found (needed by konanc's link).\n"
      'Install LLVM lld with your package manager, e.g.:\n'
      '    sudo apt-get install -y lld\n'
      'xcross does not install system packages.',
    );
  }
  final ld64Check = await ProcessRunner.run(ld64lld, ['--version']);
  if (ld64Check.exitCode != 0) {
    throw XcrossError('compose setup: ld64.lld not runnable: $ld64lld');
  }
  _info('XCROSS_LD64LLD=$ld64lld');
  return ld64lld;
}

/// Stage 3: Download K/N linux-x86_64 prebuilt into [opts.konanRoot] if absent.
///
/// The KMP Gradle build installs this exact tree at
/// `$KONAN_DATA_DIR/kotlin-native-prebuilt-linux-x86_64-<kotlinVersion>`
/// (default `~/.konan`). When it's already there we reuse it and only overlay
/// the ios_arm64 target (which Gradle can never fetch on Linux).
Future<void> _ensureKotlinNative(ComposeSetupOptions opts) async {
  final konanRoot = opts.konanRoot;
  final lxKn = opts.lxKn;
  _info('Kotlin/Native root: $konanRoot');

  if (isExecutableFile(p.join(lxKn, 'bin', 'konanc'))) {
    _info('K/N linux-x86_64 already present (reusing Gradle/local install), '
        'skipping download.');
  } else {
    _info('K/N not found at $lxKn — downloading linux-x86_64 '
        '${opts.knVersion} (~200 MB). Tip: a normal `./gradlew` build installs '
        'this automatically.');
    await _downloadUntar(
      url:
          '${opts.mavenBase}/kotlin-native-prebuilt-${opts.knVersion}-linux-x86_64.tar.gz',
      destDir: lxKn,
      stripComponents: 1,
    );
    if (!isExecutableFile(p.join(lxKn, 'bin', 'konanc'))) {
      throw XcrossError('compose setup: konanc missing after extract.');
    }
  }
}

/// Stage 5: Overlay the ios_arm64 target from the macos-x86_64 prebuilt if absent.
Future<void> _ensureIosOverlay(ComposeSetupOptions opts) async {
  final lxKn = opts.lxKn;
  final iosArm64OverlayExists = Directory(
    p.join(lxKn, 'konan', 'targets', 'ios_arm64'),
  ).existsSync();
  if (iosArm64OverlayExists) {
    _info('ios_arm64 overlay already present, skipping.');
  } else {
    _info(
        'Downloading ios_arm64 overlay from macos-x86_64 prebuilt (~250 MB)...');
    await _overlayIosArm64(
      macUrl:
          '${opts.mavenBase}/kotlin-native-prebuilt-${opts.knVersion}-macos-x86_64.tar.gz',
      lxKn: lxKn,
    );
    final iosArm64OverlayExtracted = Directory(
      p.join(lxKn, 'konan', 'targets', 'ios_arm64'),
    ).existsSync();
    if (!iosArm64OverlayExtracted) {
      throw XcrossError(
          'compose setup: ios_arm64 overlay missing after extract.');
    }
  }
}

/// Stage 6: Warm konanc's native deps (LLVM) via a throwaway host compile if absent.
Future<void> _warmDeps(ComposeSetupOptions opts, String javaHome) async {
  final konanRoot = opts.konanRoot;
  final lxKn = opts.lxKn;
  final konanDepsExists = Directory(p.join(konanRoot, 'dependencies')).existsSync();
  if (konanDepsExists) {
    _info('konan deps already warmed, skipping.');
  } else {
    _info('Warming konanc native deps (LLVM ~174 MB)...');
    await _warmKonanDeps(
      konanc: p.join(lxKn, 'bin', 'konanc'),
      konanDataDir: konanRoot,
      javaHome: javaHome,
    );
    final konanDepsWarmed = Directory(p.join(konanRoot, 'dependencies')).existsSync();
    if (!konanDepsWarmed) {
      logWarn('konan deps dir not created; konanc will fetch on first build.');
    }
  }
}

// ── internal helpers ────────────────────────────────────────────────────────

/// Download [url] and stream-extract it in pure Dart into a temp sibling of
/// [destDir], then atomically rename into place — so a mid-stream failure never
/// leaves a half-extracted tree at [destDir] (idempotent re-runs).
Future<void> _downloadUntar({
  required String url,
  required String destDir,
  int stripComponents = 0,
}) async {
  final stage =
      Directory('$destDir.dl-${DateTime.now().millisecondsSinceEpoch}');
  final stageExists = stage.existsSync();
  if (stageExists) stage.deleteSync(recursive: true);
  stage.createSync(recursive: true);
  try {
    await downloadAndExtractTarGz(
      url: url,
      dest: stage,
      stripComponents: stripComponents,
    );

    // Atomic swap into place (same filesystem — stage is a sibling).
    final destDirExists = Directory(destDir).existsSync();
    if (destDirExists) {
      Directory(destDir).deleteSync(recursive: true);
    }
    stage.renameSync(destDir);
  } catch (_) {
    final stageDirExists = stage.existsSync();
    if (stageDirExists) {
      try {
        stage.deleteSync(recursive: true);
      } catch (_) {
        // cleanup failure intentionally ignored
      }
    }
    rethrow;
  }
}

/// Stream-download the macos-x86_64 prebuilt and extract only the `ios_arm64`
/// target + platform klib slices into [lxKn] (pure Dart, no temp file).
///
/// The two wanted subtrees are matched by their stripped relative path, so the
/// archive's dynamic top-level directory name never needs to be probed.
Future<void> _overlayIosArm64({
  required String macUrl,
  required String lxKn,
}) async {
  await downloadAndExtractTarGz(
    url: macUrl,
    dest: Directory(lxKn),
    stripComponents: 1,
    keep: (rel) =>
        rel == 'konan/targets/ios_arm64' ||
        rel.startsWith('konan/targets/ios_arm64/') ||
        rel == 'klib/platform/ios_arm64' ||
        rel.startsWith('klib/platform/ios_arm64/'),
  );
}

/// Warm konanc's native dependency cache with a throwaway linux_x64 compile
/// (the host target needs no HostManager patch).
Future<void> _warmKonanDeps({
  required String konanc,
  required String konanDataDir,
  required String javaHome,
}) async {
  final warmDir = Directory.systemTemp.createTempSync('xcross-konan-warm-');
  try {
    final src = File(p.join(warmDir.path, 'w.kt'));
    await src.writeAsString('fun main() {}\n');
    // Best-effort: konanc may still emit warnings; we only care that it pulls
    // its LLVM/libffi deps into KONAN_DATA_DIR/dependencies.
    await ProcessRunner.run(
      konanc,
      [
        '-target',
        'linux_x64',
        '-p',
        'program',
        '-o',
        p.join(warmDir.path, 'w'),
        src.path,
      ],
      environment: {
        ...Platform.environment,
        'KONAN_DATA_DIR': konanDataDir,
        'JAVA_HOME': javaHome,
      },
      includeParentEnvironment: false,
    );
  } finally {
    try {
      warmDir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

/// Human-readable source of the resolved K/N version, for logging.
String _knVersionSource(Map<String, String> env, String? projectRoot) {
  if ((env['KN_VERSION'] ?? '').isNotEmpty) return 'KN_VERSION env';
  final root = projectRoot ?? Directory.current.path;
  if (resolveProjectKnVersion(root) != null) return 'project Kotlin version';
  return 'built-in default';
}

String _uname(String flag) {
  try {
    final r = Process.runSync('uname', [flag]);
    if (r.exitCode == 0) return (r.stdout as String).trim();
  } catch (_) {}
  return '';
}

void _info(String message) => logStatus('==> $message');
