import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xcross/src/constants/kotlin_native_constants.dart';

/// Resolve the K/N root: `LX_KN` env wins; otherwise probe [_knSearchRoots]
/// (plus `\$HOME/.konan`) for `kotlin-native-prebuilt-linux-x86_64-<version>`
/// and pick the highest version whose `bin/konanc` is executable.
///
/// Returns `null` if nothing usable is found — the caller reports it.
String? resolveLxKn(Map<String, String> env) {
  final override = env['LX_KN'];
  if (override != null && override.isNotEmpty) return override;

  final roots = <String>[
    ...KotlinNativeConstants.searchRoots,
    if ((env['HOME'] ?? '').isNotEmpty) p.join(env['HOME']!, '.konan'),
  ];

  final candidates = <_KnCandidate>[];
  for (final root in roots) {
    final dir = Directory(root);
    final dirExists = dir.existsSync();
    if (!dirExists) continue;
    for (final entry in dir.listSync(followLinks: false)) {
      if (entry is! Directory) continue;
      final name = p.basename(entry.path);
      if (!name.startsWith(KotlinNativeConstants.knDirPrefix)) continue;
      final version = name.substring(KotlinNativeConstants.knDirPrefix.length);
      if (version.isEmpty) continue;
      if (!isExecutableFile(p.join(entry.path, 'bin', 'konanc'))) continue;
      candidates.add(_KnCandidate(entry.path, version));
    }
  }
  if (candidates.isEmpty) return null;
  candidates.sort((a, b) => _compareVersions(b.version, a.version));
  return candidates.first.path;
}

class _KnCandidate {
  _KnCandidate(this.path, this.version);
  final String path;
  final String version;
}

/// Compare dotted numeric versions (e.g. `2.2.20` vs `2.10.0`). Non-numeric
/// tails fall back to lexicographic compare.
int _compareVersions(String a, String b) {
  final ap = a.split('.');
  final bp = b.split('.');
  final n = ap.length > bp.length ? ap.length : bp.length;
  for (var i = 0; i < n; i++) {
    final ai = i < ap.length ? int.tryParse(ap[i]) : 0;
    final bi = i < bp.length ? int.tryParse(bp[i]) : 0;
    if (ai == null || bi == null) return a.compareTo(b);
    if (ai != bi) return ai.compareTo(bi);
  }
  return 0;
}

/// Resolved locations of everything the Compose/KMP pipeline needs. Produced by
/// [resolveComposeToolchain] (probe only) or the integrated setup (provision).
///
/// Because a Dart process cannot mutate its own `Platform.environment`, these
/// values must be threaded explicitly into [ComposePacker] after a provisioning
/// run so the freshly installed tools are actually used within the same run.
class ComposeToolchain {
  const ComposeToolchain({
    this.javaHome,
    this.ld64lld,
    this.lxKn,
    this.konanDataDir,
  });

  /// JDK home for konanc + Gradle (from JAVA_HOME or a resolved `java`).
  final String? javaHome;

  /// x86_64 LLVM `ld64.lld` for konanc's framework link + the Runner link.
  final String? ld64lld;

  /// Kotlin/Native linux-x86_64 root (the `kotlin-native-prebuilt-...` dir).
  final String? lxKn;

  /// KONAN_DATA_DIR — where konanc keeps its warmed native dependency cache.
  final String? konanDataDir;

  /// Overlay [other]'s non-null fields on top of this one.
  ComposeToolchain merge(ComposeToolchain other) => ComposeToolchain(
        javaHome: other.javaHome ?? javaHome,
        ld64lld: other.ld64lld ?? ld64lld,
        lxKn: other.lxKn ?? lxKn,
        konanDataDir: other.konanDataDir ?? konanDataDir,
      );

  /// Environment overrides to inject into child processes (gradle/konanc).
  Map<String, String> toEnv() => {
        if (javaHome != null && javaHome!.isNotEmpty) 'JAVA_HOME': javaHome!,
        if (ld64lld != null && ld64lld!.isNotEmpty) 'XCROSS_LD64LLD': ld64lld!,
        if (lxKn != null && lxKn!.isNotEmpty) 'LX_KN': lxKn!,
        if (konanDataDir != null && konanDataDir!.isNotEmpty)
          'KONAN_DATA_DIR': konanDataDir!,
      };
}

/// Best-effort resolution of the toolchain locations from [env] + the
/// filesystem, without validating that everything is present. Missing pieces
/// come back as `null`.
ComposeToolchain resolveComposeToolchain(Map<String, String> env) {
  // JAVA_HOME: explicit env, else derive from a `java` on PATH.
  var javaHome = env['JAVA_HOME'];
  if (javaHome == null ||
      javaHome.isEmpty ||
      !isExecutableFile(p.join(javaHome, 'bin', 'java'))) {
    javaHome = _javaHomeFromPath();
  }

  // ld64.lld: explicit env wins, else probe stock LLVM locations.
  var ld64lld = env['XCROSS_LD64LLD'];
  if (ld64lld == null || ld64lld.isEmpty || !isExecutableFile(ld64lld)) {
    ld64lld = findLd64Lld();
  }

  final lxKn = resolveLxKn(env);

  final konanDataDir = (env['KONAN_DATA_DIR']?.isNotEmpty ?? false)
      ? env['KONAN_DATA_DIR']
      : KotlinNativeConstants.defaultKonanRoot;

  return ComposeToolchain(
    javaHome: javaHome,
    ld64lld: ld64lld,
    lxKn: lxKn,
    konanDataDir: konanDataDir,
  );
}

/// One failed toolchain requirement.
class ComposeProblem {
  ComposeProblem(this.what, this.detail, this.fix);
  final String what;
  final String detail;
  final String fix;
}

/// Check the host toolchain against [env] and return every unmet requirement.
///
/// An empty list means the host is ready for `xcross compose`. This is the pure
/// validation core shared by the fast-path guard and the post-setup re-check.
List<ComposeProblem> collectComposeProblems(Map<String, String> env) {
  final problems = <ComposeProblem>[];

  // 1. Architecture — Kotlin/Native konanc has no linux-aarch64 prebuilt.
  if (Platform.isLinux && _uname('-m') != 'x86_64') {
    problems.add(ComposeProblem(
      'CPU architecture',
      'compose requires x86_64 (got ${_uname('-m')}); Kotlin/Native konanc '
          'ships no linux-aarch64 prebuilt.',
      'Run on an x86_64 host, or under Rosetta/emulation with binfmt.',
    ));
  }

  // 2. JAVA_HOME / java — konanc JVM + Gradle daemon.
  final javaHome = env['JAVA_HOME'];
  final javaOk = (javaHome != null &&
          javaHome.isNotEmpty &&
          isExecutableFile(p.join(javaHome, 'bin', 'java'))) ||
      _onPath('java');
  if (!javaOk) {
    problems.add(ComposeProblem(
      'JDK (JAVA_HOME)',
      'no JDK found — needed by konanc and Gradle.',
      'Install a JDK 21 and export JAVA_HOME '
          '(e.g. /usr/lib/jvm/java-21-openjdk-amd64).',
    ));
  }

  // 3. ld64.lld (XCROSS_LD64LLD) — konanc's framework link + Runner link.
  //    The Darwin bundle's own ld64.lld is aarch64 and cannot be spawned by the
  //    x86_64 konanc, so a stock LLVM x86_64 ld64.lld must be pointed at here.
  //    Accept a discoverable stock ld64.lld even if XCROSS_LD64LLD is unset.
  //
  //    Two distinct failure modes checked in order (mutually exclusive):
  //      a) no ld64.lld found at all → push "not found" problem.
  //      b) found but not executable  → push "not executable" problem.
  //    Order is significant: (b) is only reachable when (a) is false.
  final ld64lld = env['XCROSS_LD64LLD'];
  final resolvedLd64 =
      (ld64lld != null && ld64lld.isNotEmpty) ? ld64lld : findLd64Lld();
  if (resolvedLd64 == null || resolvedLd64.isEmpty) {
    problems.add(ComposeProblem(
      'ld64.lld (XCROSS_LD64LLD)',
      'XCROSS_LD64LLD is not set and no stock LLVM ld64.lld was found; the '
          'Darwin bundle fallback is aarch64 and konanc cannot spawn it under '
          'x86_64.',
      'Install LLVM lld and export XCROSS_LD64LLD '
          '(e.g. /usr/lib/llvm-18/bin/ld64.lld).',
    ));
  } else if (!isExecutableFile(resolvedLd64)) {
    problems.add(ComposeProblem(
      'ld64.lld (XCROSS_LD64LLD)',
      'ld64.lld path "$resolvedLd64" is not an executable file.',
      'Point XCROSS_LD64LLD at a real x86_64 LLVM ld64.lld.',
    ));
  }

  // 4. clang — cross-compiles the ObjC Runner to arm64-ios.
  if (!_onPath('clang')) {
    problems.add(ComposeProblem(
      'clang',
      'clang not found on PATH — needed to compile the ObjC Runner.',
      'Install clang (e.g. `apt-get install clang`).',
    ));
  }

  // 5. Kotlin/Native root (LX_KN) — konanc + the ios_arm64 target overlay.
  //    Auto-detect any installed version under /opt/konan or ~/.konan; LX_KN
  //    still wins so users can pin a specific tree.
  final lxKn = resolveLxKn(env);
  if (lxKn == null) {
    problems.add(ComposeProblem(
      'Kotlin/Native (LX_KN)',
      'no kotlin-native-prebuilt-linux-x86_64-<version> found under '
          r'/opt/konan or $HOME/.konan, and LX_KN is not set.',
      'Let `xcross compose` provision it automatically, run '
          '`xcross compose setup`, or export LX_KN.',
    ));
  } else if (!isExecutableFile(p.join(lxKn, 'bin', 'konanc'))) {
    problems.add(ComposeProblem(
      'Kotlin/Native (LX_KN)',
      'konanc not found at "${p.join(lxKn, 'bin', 'konanc')}".',
      'Let `xcross compose` provision it automatically, or run '
          '`xcross compose setup`.',
    ));
  } else {
    final iosArm64TargetExists = Directory(
      p.join(lxKn, 'konan', 'targets', 'ios_arm64'),
    ).existsSync();
    if (!iosArm64TargetExists) {
      // The linux prebuilt ships no ios_arm64 target dir; it must be overlaid
      // from the macos-x86_64 prebuilt. Without it konanc fails at stage 6.
      problems.add(ComposeProblem(
        'Kotlin/Native ios_arm64 overlay',
        'ios_arm64 target missing under "$lxKn/konan/targets".',
        'Let `xcross compose` provision it automatically, or run '
            '`xcross compose setup`.',
      ));
    }
  }

  // NB: `gradle` is intentionally NOT required. The packer's only gradle use is
  // the best-effort Stage 0 warmup (failure ignored); konanc compiles the
  // Kotlin sources directly. Requiring it would wrongly block otherwise-buildable
  // hosts (and the integrated setup doesn't install it) — mirrors the shell
  // script's "non-fatal" treatment.

  return problems;
}

/// Render [problems] into the multi-line, actionable error message shown when
/// the host toolchain cannot be made ready.
String formatComposeProblems(List<ComposeProblem> problems) {
  final b = StringBuffer()
    ..writeln('compose: host toolchain is not ready '
        '(${problems.length} problem${problems.length == 1 ? '' : 's'}).')
    ..writeln();
  for (final pr in problems) {
    b
      ..writeln('  ✗ ${pr.what}')
      ..writeln('      ${pr.detail}')
      ..writeln('      fix: ${pr.fix}');
  }
  b
    ..writeln()
    ..writeln('The Kotlin/Native pieces are downloaded automatically (no root) '
        'by `xcross compose build/run`, or up front with:')
    ..writeln('    xcross compose setup')
    ..writeln('System packages (JDK, clang, lld) are prerequisites — install '
        'them with your package manager (xcross never runs sudo).')
    ..writeln()
    ..writeln('Or bypass this check with XCROSS_SKIP_PREFLIGHT=1 if your '
        'environment resolves these differently.');
  return b.toString();
}

// ── shared helpers (also used by compose_setup.dart) ────────────────────────

bool isTruthyEnv(String? v) =>
    v != null && const {'1', 'true', 'yes', 'on'}.contains(v.toLowerCase());

bool isExecutableFile(String path) {
  final f = File(path);
  final fileExists = f.existsSync();
  if (!fileExists) return false;
  // On POSIX, check the owner/group/other execute bits.
  final mode = f.statSync().mode;
  return mode & 0x49 != 0; // 0o111
}

bool _onPath(String exe) {
  final pathEnv = Platform.environment['PATH'] ?? '';
  for (final dir in pathEnv.split(Platform.isWindows ? ';' : ':')) {
    if (dir.isEmpty) continue;
    if (isExecutableFile(p.join(dir, exe))) return true;
  }
  return false;
}

/// Locate a real iOS-capable stock LLVM `ld64.lld` (the swift image's own one
/// is Apple-stubbed). Returns `null` if none is found.
String? findLd64Lld() {
  // Explicit stock-LLVM install dirs first (glob /usr/lib/llvm-*/bin/ld64.lld).
  final llvmRoot = Directory('/usr/lib');
  final llvmRootExists = llvmRoot.existsSync();
  if (llvmRootExists) {
    for (final entry in llvmRoot.listSync(followLinks: false)) {
      if (entry is! Directory) continue;
      if (!p.basename(entry.path).startsWith('llvm-')) continue;
      final cand = p.join(entry.path, 'bin', 'ld64.lld');
      if (isExecutableFile(cand)) return cand;
    }
  }
  // Then anything named ld64.lld on PATH.
  final pathEnv = Platform.environment['PATH'] ?? '';
  for (final dir in pathEnv.split(Platform.isWindows ? ';' : ':')) {
    if (dir.isEmpty) continue;
    final cand = p.join(dir, 'ld64.lld');
    if (isExecutableFile(cand)) return cand;
  }
  return null;
}

/// Derive JAVA_HOME from a `java` on PATH by resolving symlinks two levels up
/// (…/jvm/<jdk>/bin/java → …/jvm/<jdk>). Returns `null` if `java` isn't found.
String? _javaHomeFromPath() {
  final pathEnv = Platform.environment['PATH'] ?? '';
  for (final dir in pathEnv.split(Platform.isWindows ? ';' : ':')) {
    if (dir.isEmpty) continue;
    final javaBin = p.join(dir, 'java');
    if (!isExecutableFile(javaBin)) continue;
    try {
      final real = File(javaBin).resolveSymbolicLinksSync();
      // …/<home>/bin/java → <home>
      final home = p.dirname(p.dirname(real));
      if (isExecutableFile(p.join(home, 'bin', 'java'))) return home;
    } catch (_) {}
    return p.dirname(dir); // fallback: parent of the bin dir
  }
  return null;
}

/// Best-effort `uname` lookup; returns '' if unavailable.
String _uname(String flag) {
  try {
    final r = Process.runSync('uname', [flag]);
    if (r.exitCode == 0) return (r.stdout as String).trim();
  } catch (_) {}
  return '';
}
