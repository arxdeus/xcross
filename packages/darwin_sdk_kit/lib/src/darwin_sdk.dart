import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/src/errors.dart';
import 'package:path/path.dart' as p;

/// An xcross-owned Swift SDK artifact bundle containing the Darwin SDK files
/// needed to build for iOS.
final class DarwinSdk {
  DarwinSdk(this.bundle);

  /// Root of `xcross-darwin.artifactbundle`.
  final String bundle;

  static final RegExp _digitPattern = RegExp('[0-9]');
  static String? _installBundleOverride;

  /// Configures the bundle used by [nativeInstallDir] and [current].
  ///
  /// Intended for embedders and tests that need an isolated SDK installation.
  static void configureInstallBundleOverride(String? bundle) {
    _installBundleOverride = bundle;
  }

  /// Removes the configured install-bundle override.
  static void resetInstallBundleOverride() => _installBundleOverride = null;

  /// Artifact bundle path whose parent is passed to `--swift-sdks-path`.
  String get swiftSdkPath => bundle;

  /// Where `xcross sdk install <Xcode.xip>` installs the Swift SDK bundle.
  static String nativeInstallDir({String? configDir}) =>
      configDir == null && _installBundleOverride != null
      ? _installBundleOverride!
      : p.join(
          configDir ?? _configDir(),
          'xcross',
          'swift-sdks',
          'xcross-darwin.artifactbundle',
        );

  /// Resolve the SDK installed and owned by xcross, or null when incomplete.
  static DarwinSdk? current({String? bundle}) {
    final candidate = bundle ?? _installBundleOverride ?? nativeInstallDir();
    final source = _canonicalLayout(candidate);
    final destination = _runtimeLayout(candidate);
    try {
      if (!_hasContent(destination) && _hasContent(source)) {
        destination.parent.createSync(recursive: true);
        source.copySync(destination.path);
      }
    } on FileSystemException catch (e) {
      Log.logTrace('DarwinSdk: could not stage runtime layout: $e');
    }
    return isValidBundle(candidate) ? DarwinSdk(candidate) : null;
  }

  /// A complete bundle has Swift artifact metadata and a usable iPhoneOS SDK.
  static bool isValidBundle(String candidate) {
    const metadata = ['info.json', 'swift-sdk.json', 'toolset.json'];
    if (!metadata.every((n) => File(p.join(candidate, n)).existsSync())) {
      return false;
    }

    final sdk = _firstSdk(_sdksDir(candidate, 'iPhoneOS'), 'iPhoneOS');
    if (sdk == null) return false;

    final canonicalLayout = _canonicalLayout(candidate);
    final swiftResources = canonicalLayout.parent;
    return Directory(
          p.join(sdk, 'System', 'Library', 'Frameworks'),
        ).existsSync() &&
        swiftResources.existsSync() &&
        _hasContent(canonicalLayout) &&
        _hasContent(_runtimeLayout(candidate));
  }

  static bool _hasContent(File file) =>
      file.existsSync() && file.lengthSync() > 0;

  /// First versioned iPhoneOSXX.X.sdk found, else first iPhoneOS.sdk.
  String iPhoneOSSdk() {
    final dir = _sdksDir(bundle, 'iPhoneOS');
    final pick = _firstSdk(dir, 'iPhoneOS');
    if (pick == null) {
      throw DarwinSdkError(
        'DarwinSdk: Could not find an iPhoneOS SDK under $dir.\n'
        'Install one with `xcross sdk install <Xcode.xip>`.',
      );
    }
    return pick;
  }

  static String _sdksDir(String bundle, String platform) => p.join(
    bundle,
    'Developer',
    'Platforms',
    '$platform.platform',
    'Developer',
    'SDKs',
  );

  static File _canonicalLayout(String bundle) => File(
    p.join(
      bundle,
      'Developer',
      'Toolchains',
      'XcodeDefault.xctoolchain',
      'usr',
      'lib',
      'swift',
      'iphoneos',
      'layouts-arm64.yaml',
    ),
  );

  static File _runtimeLayout(String bundle) => File(
    p.join(
      bundle,
      'Developer',
      'Runtimes',
      'XcodeDefault.xctoolchain',
      'usr',
      'bin',
      'layouts-arm64.yaml',
    ),
  );

  static String? _firstSdk(String dir, String prefix) {
    final directory = Directory(dir);
    if (!directory.existsSync()) return null;
    final names =
        directory
            .listSync()
            .where(
              (entry) =>
                  entry is Directory ||
                  FileSystemEntity.typeSync(entry.path) ==
                      FileSystemEntityType.directory,
            )
            .map((entry) => p.basename(entry.path))
            .where((name) => name.startsWith(prefix) && name.endsWith('.sdk'))
            .toList()
          ..sort();

    final pick =
        names.where((name) => name.contains(_digitPattern)).firstOrNull ??
        names.firstOrNull;
    return pick == null ? null : p.join(dir, pick);
  }

  static String _configDir() {
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      if (appData != null && appData.isNotEmpty) return appData;
    }
    final xdg = Platform.environment['XDG_CONFIG_HOME'];
    if (xdg != null && xdg.isNotEmpty) return xdg;
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    return p.join(home, '.config');
  }

  /// Resolve the Apple-compatible linker from PATH on every host.
  ///
  /// The `ld64.lld` a Swift toolchain ships beside its own `swift` refuses to
  /// link for iOS ("This version of lld does not support linking for platform
  /// iOS"), on Linux through swiftly's proxy shims and on Windows through the
  /// official installer's copy. Stock LLVM ships no `swift`, so candidates
  /// without one next to them come first — but a co-located linker is still
  /// tried, since distributions that install Swift and LLVM into the same
  /// `bin` are fine.
  ///
  /// Every candidate is asked to link for iOS before it is handed out
  /// ([probeIosSupport]): a linker that cannot is worse than none at all,
  /// because it fails deep inside a build, and on Windows it can die with no
  /// output whatsoever.
  ///
  /// Among the linkers that pass, one free of the selector-stub defect
  /// ([selectorStubDefect]) wins over one that has it, regardless of PATH
  /// order; a defective linker is still handed out when it is the only one,
  /// with a warning.
  static Future<String> resolveLd64Lld(
    DarwinSdk _, {
    Future<CapturedProcess> Function(String, List<String>)? runProcess,
  }) async {
    final searched = llvmToolDirs();
    final candidates = await ProcessRunner.whichAll(
      'ld64.lld',
      accept: usableLd64Lld,
      extraDirectories: searched,
    );
    final ordered = [
      ...candidates.where((path) => !_besideSwift(path)),
      ...candidates.where(_besideSwift),
    ];

    final rejected = <String>[];
    String? defective;
    for (final candidate in ordered) {
      final failure = await probeIosSupport(candidate, runProcess: runProcess);
      if (failure != null) {
        Log.logTrace('ld64.lld: skipping $candidate — $failure');
        rejected.add('  $candidate\n    $failure');
        continue;
      }
      final defect = await selectorStubDefect(
        candidate,
        runProcess: runProcess,
      );
      if (defect == null) return candidate;
      Log.logTrace('ld64.lld: $candidate — $defect');
      defective ??= candidate;
    }
    if (defective != null) {
      if (_warnedDefective.add(defective)) {
        Log.logWarn(
          'Using $defective: '
          '${await selectorStubDefect(defective, runProcess: runProcess)}',
        );
      }
      return defective;
    }

    final where = [
      'Looked on PATH and in:',
      for (final dir in searched) '  $dir',
    ].join('\n');
    throw DarwinSdkError(
      rejected.isEmpty
          ? "No 'ld64.lld' found.\n$where\n$_installLinkerHint"
          : "No 'ld64.lld' that can link for iOS.\n"
                '${rejected.join('\n')}\n$where\n$_installLinkerHint',
    );
  }

  /// Where a stock LLVM install sits when nobody put it on PATH.
  ///
  /// winget's LLVM package registers no PATH entry at all
  /// (microsoft/winget-pkgs#11767), and Debian keeps versioned toolchains
  /// under `/usr/lib`, so the tools are installed but invisible to a plain
  /// PATH lookup. Homebrew is keg-only for `llvm` and split `lld` into its
  /// own formula (`ld64.lld` lives in `opt/lld/bin`), under `/opt/homebrew`
  /// (Apple Silicon) or `/usr/local` (Intel).
  static List<String> llvmToolDirs({
    Map<String, String>? environment,
    bool? windows,
  }) {
    final env = environment ?? Platform.environment;
    if (windows ?? Platform.isWindows) {
      // The machine-wide installer lands in Program Files, the per-user one
      // under LOCALAPPDATA\Programs.
      const roots = {
        'ProgramFiles': 'LLVM',
        'ProgramW6432': 'LLVM',
        'ProgramFiles(x86)': 'LLVM',
        'LOCALAPPDATA': r'Programs\LLVM',
      };
      return [
        for (final root in roots.entries)
          if ((env[root.key] ?? '').isNotEmpty)
            p.windows.join(env[root.key]!, root.value, 'bin'),
      ];
    }
    return [
      ..._versionedLlvmBins(),
      '/opt/homebrew/opt/lld/bin',
      '/opt/homebrew/opt/llvm/bin',
      '/usr/local/opt/lld/bin',
      '/usr/local/opt/llvm/bin',
    ];
  }

  /// Debian's `/usr/lib/llvm-<version>/bin`, newest version first.
  static List<String> _versionedLlvmBins() {
    final lib = Directory('/usr/lib');
    if (!lib.existsSync()) return const [];
    final versions =
        lib
            .listSync()
            .map((entry) => p.basename(entry.path))
            .where((name) => name.startsWith('llvm-'))
            .toList()
          ..sort((a, b) {
            final left = int.tryParse(a.substring(5).split('.').first) ?? -1;
            final right = int.tryParse(b.substring(5).split('.').first) ?? -1;
            return right.compareTo(left);
          });
    return [for (final name in versions) p.join('/usr/lib', name, 'bin')];
  }

  /// PATH lookup for an LLVM tool that also reaches into [llvmToolDirs].
  static Future<String?> locateLlvmTool(String name) =>
      ProcessRunner.which(name, extraDirectories: llvmToolDirs());

  static String get _installLinkerHint => Platform.isWindows
      ? "The Swift toolchain's own ld64.lld cannot link Mach-O for iOS. "
            'Install stock LLVM — `winget install --id LLVM.LLVM --exact` — '
            'into one of the directories above, or add the bin directory of '
            'an existing install to PATH.'
      : Platform.isMacOS
      ? 'Install the LLVM one — `brew install lld && brew install llvm`, or `xcross setup` — '
            'and make sure it is on PATH.'
      : 'Install the LLVM one — `xcross setup`, or `sudo apt install lld` — '
            'and make sure it is on PATH.';

  /// First ld64.lld release that wires `_objc_msgSend$<selector>` stubs to
  /// the right selector.
  ///
  /// Up to and including LLVM 18, `ObjCStubsSection::setUp` scaled every
  /// synthesised `__objc_selrefs` addend by the `__objc_methname` output
  /// alignment (`offsets[i] * in.objcMethnameSection->align`). One input
  /// object declaring that section with an alignment above 1 is enough to
  /// send every stub's selector reference to the wrong string — a silent
  /// runtime failure in any Objective-C plugin. LLVM 19 rewrote the stubs
  /// around `ObjCSelRefsHelper` and dropped the multiply.
  static const int firstLd64LldWithCorrectSelectorStubs = 19;

  /// Why [linker] miswires Objective-C selector stubs, or null when it does
  /// not (or its version cannot be told, which is not held against it).
  static Future<String?> selectorStubDefect(
    String linker, {
    Future<CapturedProcess> Function(String, List<String>)? runProcess,
  }) async {
    final version = await ld64LldVersion(linker, runProcess: runProcess);
    if (version == null || version.$1 >= firstLd64LldWithCorrectSelectorStubs) {
      return null;
    }
    return 'ld64.lld ${version.$1}.${version.$2} miswires Objective-C '
        r'selector stubs (`_objc_msgSend$<selector>`), which breaks '
        'Objective-C plugins at runtime. Install lld '
        '$firstLd64LldWithCorrectSelectorStubs or newer — '
        '`xcross setup` does that where the distribution ships it.';
  }

  /// `(major, minor)` of [linker] as reported by `--version`, or null when
  /// the tool cannot be run or prints no `LLD <version>`.
  static Future<(int, int)?> ld64LldVersion(
    String linker, {
    Future<CapturedProcess> Function(String, List<String>)? runProcess,
  }) async {
    if (_versions.containsKey(linker)) return _versions[linker];
    (int, int)? version;
    try {
      final result = await (runProcess ?? ProcessRunner.run)(linker, [
        '--version',
      ]);
      final match = _lldVersion.firstMatch(
        '${result.stdout}\n${result.stderr}',
      );
      if (match != null) {
        version = (int.parse(match.group(1)!), int.parse(match.group(2)!));
      }
    } on Object catch (error) {
      Log.logTrace('ld64.lld: $linker --version failed: $error');
    }
    return _versions[linker] = version;
  }

  /// `LLD 18.1.3`, `Ubuntu LLD 18.1.3 (compatible with Apple linkers)`,
  /// `Homebrew LLD 22.1.8`, `LLD 21.0.0 (https://github.com/swiftlang/...)`.
  static final RegExp _lldVersion = RegExp(r'\bLLD (\d+)\.(\d+)');

  /// `--version` results by linker path; a null value is a remembered miss.
  static final Map<String, (int, int)?> _versions = {};

  static final Set<String> _warnedDefective = {};

  /// Why [linker] cannot link for iOS, or null when it can.
  ///
  /// Asks for an iOS dylib with an input that does not exist: a working linker
  /// gets as far as complaining about the missing file, while one built
  /// without Mach-O iOS support rejects the platform first. Only positive
  /// evidence of failure counts, so an unfamiliar diagnostic is treated as a
  /// working linker rather than locking a user out of their own toolchain.
  static Future<String?> probeIosSupport(
    String linker, {
    Future<CapturedProcess> Function(String, List<String>)? runProcess,
  }) async {
    final cached = _iosSupport[linker];
    if (cached != null) return cached.isEmpty ? null : cached;

    // Inside a directory that is never created, so the probe cannot pick up a
    // stray object file and actually link something.
    final missing = p.join(
      Directory.systemTemp.path,
      'xcross-ld64-probe',
      'probe.o',
    );
    final CapturedProcess result;
    try {
      result = await (runProcess ?? ProcessRunner.run)(linker, [
        '-arch',
        'arm64',
        '-platform_version',
        'ios',
        '13.0',
        '13.0',
        '-dylib',
        '-o',
        '$missing.dylib',
        missing,
      ]);
    } on Object catch (error) {
      return _rememberIosSupport(linker, 'could not be run: $error');
    }

    final output = '${result.stdout}\n${result.stderr}';
    final unsupported = _unsupportedIosLink.firstMatch(output);
    if (unsupported != null) {
      return _rememberIosSupport(
        linker,
        output
            .split('\n')
            .firstWhere(_unsupportedIosLink.hasMatch)
            .trim()
            .replaceFirst(RegExp('^.*?: *'), ''),
      );
    }
    if (ProcessRunner.crashed(result.exitCode)) {
      return _rememberIosSupport(
        linker,
        'crashed on an iOS link: '
        '${ProcessRunner.describeExitCode(result.exitCode)}',
      );
    }
    return _rememberIosSupport(linker, null);
  }

  static String? _rememberIosSupport(String linker, String? failure) {
    _iosSupport[linker] = failure ?? '';
    return failure;
  }

  /// Resolve a clang that can drive a Darwin target, preferring stock LLVM.
  ///
  /// The same preference as [resolveLd64Lld], for the same reason: a Swift
  /// toolchain's own clang is built for that toolchain's host targets, and the
  /// Windows 6.3.3 one fast-fails on an Xcode 26 sysroot before it prints
  /// anything at all. [name] selects `clang` or `clang++`.
  static Future<String> resolveDarwinClang(
    DarwinSdk sdk, {
    String name = 'clang',
    Future<CapturedProcess> Function(String, List<String>)? runProcess,
  }) async {
    final sysroot = sdk.iPhoneOSSdk();

    // An explicit CC/CXX override takes precedence over the PATH search
    // below — this matters on systems (e.g. Nix) where a stray system
    // compiler sits ahead of the intended one on PATH.
    final envVar = name == 'clang++' ? 'CXX' : 'CC';
    final override = ProcessRunner.effectiveEnvironment[envVar];
    if (override != null && override.isNotEmpty) {
      final failure = await probeDarwinDriver(
        override,
        sysroot: sysroot,
        runProcess: runProcess,
      );
      if (failure == null) return override;
      throw DarwinSdkError(
        "\$$envVar is set to '$override' but it cannot target iOS.\n"
        '  $failure',
      );
    }

    final searched = llvmToolDirs();
    final candidates = await ProcessRunner.whichAll(
      name,
      extraDirectories: searched,
    );
    final ordered = [
      ...candidates.where((path) => !_besideSwift(path)),
      ...candidates.where(_besideSwift),
    ];

    final rejected = <String>[];
    for (final candidate in ordered) {
      final failure = await probeDarwinDriver(
        candidate,
        sysroot: sysroot,
        runProcess: runProcess,
      );
      if (failure == null) return candidate;
      Log.logTrace('$name: skipping $candidate — $failure');
      rejected.add('  $candidate\n    $failure');
    }

    final where = [
      'Looked on PATH and in:',
      for (final dir in searched) '  $dir',
    ].join('\n');
    throw DarwinSdkError(
      rejected.isEmpty
          ? "No '$name' found.\n$where\n$_installClangHint"
          : "No '$name' that can target iOS.\n"
                '${rejected.join('\n')}\n$where\n$_installClangHint',
    );
  }

  static String get _installClangHint => Platform.isWindows
      ? 'Install stock LLVM — `winget install --id LLVM.LLVM --exact` — into '
            'one of the directories above, or add the bin directory of an '
            'existing install to PATH.'
      : 'Install LLVM — `xcross setup`, or `sudo apt install clang` — and make '
            'sure it is on PATH.';

  /// Why [clang] cannot be pointed at a Darwin [sysroot], or null when it can.
  ///
  /// `-###` makes the driver do all of its Darwin work — resolving the
  /// toolchain, reading the SDK settings, computing the deployment target —
  /// and then print the commands instead of running any of them, so the probe
  /// costs one process and writes nothing. A driver that dies there dies on
  /// every real compile too.
  static Future<String?> probeDarwinDriver(
    String clang, {
    required String sysroot,
    Future<CapturedProcess> Function(String, List<String>)? runProcess,
  }) async {
    final cached = _darwinDrivers[clang];
    if (cached != null) return cached.isEmpty ? null : cached;

    final missing = p.join(
      Directory.systemTemp.path,
      'xcross-clang-probe',
      'probe.c',
    );
    final CapturedProcess result;
    try {
      result = await (runProcess ?? ProcessRunner.run)(clang, [
        '-###',
        '--target=arm64-apple-ios13.0',
        '-arch',
        'arm64',
        '-isysroot',
        sysroot,
        '-x',
        'c',
        missing,
        '-c',
        '-o',
        '$missing.o',
      ]);
    } on Object catch (error) {
      return _rememberDarwinDriver(clang, 'could not be run: $error');
    }

    // A missing input file is expected and says nothing about the driver, so
    // only an outright crash disqualifies a candidate.
    if (ProcessRunner.crashed(result.exitCode)) {
      return _rememberDarwinDriver(
        clang,
        'crashed on a Darwin driver run: '
        '${ProcessRunner.describeExitCode(result.exitCode)}',
      );
    }
    return _rememberDarwinDriver(clang, null);
  }

  static String? _rememberDarwinDriver(String clang, String? failure) {
    _darwinDrivers[clang] = failure ?? '';
    return failure;
  }

  /// Probe verdicts by clang path; the empty string means "usable".
  static final Map<String, String> _darwinDrivers = {};

  /// Probe verdicts by linker path; the empty string means "usable".
  static final Map<String, String> _iosSupport = {};

  static final RegExp _unsupportedIosLink = RegExp(
    'does not support linking for platform|unknown platform|'
    'missing or unsupported -arch',
    caseSensitive: false,
  );

  /// PATH filter for [resolveLd64Lld] and the `xcross setup` requirement check.
  static bool usableLd64Lld(String path) => !ProcessRunner.isSwiftlyProxy(path);

  static bool _besideSwift(String path) {
    final dir = p.dirname(path);
    return File(p.join(dir, 'swift')).existsSync() ||
        File(p.join(dir, 'swift.exe')).existsSync();
  }
}
