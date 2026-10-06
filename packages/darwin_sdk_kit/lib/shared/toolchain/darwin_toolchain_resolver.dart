import 'dart:io';

import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:cli_kit/shared/process/process_models.dart';
import 'package:darwin_sdk_kit/host/shared/darwin_toolchain_locations.dart';
import 'package:darwin_sdk_kit/shared/errors/errors.dart';
import 'package:meta/meta.dart';

final class DarwinToolchainResolver<T extends PlatformHostInterface> {
  DarwinToolchainResolver(this.runner, this.locations);
  T get host => runner.host;
  Log get log => runner.log;
  final ProcessRunner<T> runner;
  final DarwinToolchainLocationsInterface locations;
  Future<String> resolveLd64Lld({
    Future<CapturedProcess> Function(String, List<String>)? runProcess,
  }) async {
    final searched = llvmToolDirs();
    final candidates = await runner.whichAll(
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
        log.logTrace('ld64.lld: skipping $candidate — $failure');
        rejected.add('  $candidate\n    $failure');
        continue;
      }
      final defect = await selectorStubDefect(
        candidate,
        runProcess: runProcess,
      );
      if (defect == null) return candidate;
      log.logTrace('ld64.lld: $candidate — $defect');
      defective ??= candidate;
    }
    if (defective != null) {
      if (_warnedDefective.add(defective)) {
        log.logWarn(
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

  List<String> llvmToolDirs() => locations.llvmToolDirectories();
  Future<String?> locateLlvmTool(String name) =>
      runner.which(name, extraDirectories: llvmToolDirs());
  String get _installLinkerHint => locations.linkerInstallationHint;

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
  Future<String?> selectorStubDefect(
    String linker, {
    Future<CapturedProcess> Function(String, List<String>)? runProcess,
  }) async {
    final version = await ld64LldVersion(linker, runProcess: runProcess);
    if (version == null || version.$1 >= firstLd64LldWithCorrectSelectorStubs) {
      return null;
    }
    return 'ld64.lld ${version.$1}.${version.$2} miswires Objective-C '
        r'selector stubs (`_objc_msgSend$<selector>`). xcross repairs the '
        'output it produces, so builds still run, but the repair is not '
        'needed at all on lld $firstLd64LldWithCorrectSelectorStubs or '
        'newer. Install lld $firstLd64LldWithCorrectSelectorStubs+ — '
        '`xcross setup` does that where the distribution ships it.';
  }

  /// `(major, minor)` of [linker] as reported by `--version`, or null when
  /// the tool cannot be run or prints no `LLD <version>`.
  Future<(int, int)?> ld64LldVersion(
    String linker, {
    Future<CapturedProcess> Function(String, List<String>)? runProcess,
  }) async {
    if (_versions.containsKey(linker)) return _versions[linker];
    (int, int)? version;
    try {
      final result = await (runProcess ?? runner.run)(linker, ['--version']);
      final match = _lldVersion.firstMatch(
        '${result.stdout}\n${result.stderr}',
      );
      if (match != null) {
        version = (int.parse(match.group(1)!), int.parse(match.group(2)!));
      }
    } on Object catch (error) {
      log.logTrace('ld64.lld: $linker --version failed: $error');
    }
    return _versions[linker] = version;
  }

  /// `LLD 18.1.3`, `Ubuntu LLD 18.1.3 (compatible with Apple linkers)`,
  /// `Homebrew LLD 22.1.8`, `LLD 21.0.0 (https://github.com/swiftlang/...)`.
  final RegExp _lldVersion = RegExp(r'\bLLD (\d+)\.(\d+)');

  /// `--version` results by linker path; a null value is a remembered miss.
  final Map<String, (int, int)?> _versions = {};

  final Set<String> _warnedDefective = {};

  /// Why [linker] cannot link for iOS, or null when it can.
  ///
  /// Asks for an iOS dylib from an empty arm64 object built for iOS: a linker
  /// without Mach-O iOS support rejects the platform once it reads the
  /// object. Only positive evidence of failure counts, so an unfamiliar
  /// diagnostic is treated as a working linker rather than locking a user out
  /// of their own toolchain.
  Future<String?> probeIosSupport(
    String linker, {
    Future<CapturedProcess> Function(String, List<String>)? runProcess,
  }) async {
    final cached = _iosSupport[linker];
    if (cached != null) return cached.isEmpty ? null : cached;

    Directory? scratch;
    var object = host.paths.context.join(
      host.paths.temporaryRoot,
      'xcross-ld64-probe',
      'probe.o',
    );
    try {
      scratch = await host.fileSystem
          .directory(host.paths.temporaryRoot)
          .createTemp('xcross-ld64-probe-');
      final written = host.paths.context.join(scratch.path, 'probe.o');
      await host.fileSystem.file(written).writeAsBytes(iosProbeObject);
      object = written;
    } on Object catch (error) {
      log.logTrace('ld64.lld: probe object unavailable: $error');
    }
    final CapturedProcess result;
    try {
      result = await (runProcess ?? runner.run)(linker, [
        '-arch',
        'arm64',
        '-platform_version',
        'ios',
        '13.0',
        '13.0',
        '-dylib',
        '-o',
        '$object.dylib',
        object,
      ]);
    } on Object catch (error) {
      return _rememberIosSupport(linker, 'could not be run: $error');
    } finally {
      try {
        await scratch?.delete(recursive: true);
      } on Object catch (error) {
        log.logTrace('ld64.lld: probe cleanup failed: $error');
      }
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
    if (runner.crashed(result.exitCode)) {
      return _rememberIosSupport(
        linker,
        'crashed on an iOS link: '
        '${runner.describeExitCode(result.exitCode)}',
      );
    }
    return _rememberIosSupport(linker, null);
  }

  @internal
  static final List<int> iosProbeObject = List.unmodifiable([
    ..._littleEndianWords([0xfeedfacf, 0x0100000c, 0, 1, 1, 24, 0, 0]),
    ..._littleEndianWords([0x32, 24, 2, 0x000d0000, 0x000d0000, 0]),
  ]);

  static List<int> _littleEndianWords(List<int> words) => [
    for (final word in words)
      for (var shift = 0; shift < 32; shift += 8) (word >> shift) & 0xff,
  ];

  String? _rememberIosSupport(String linker, String? failure) {
    _iosSupport[linker] = failure ?? '';
    return failure;
  }

  /// Resolve a clang that can drive a Darwin target, preferring stock LLVM.
  ///
  /// The same preference as [resolveLd64Lld], for the same reason: a Swift
  /// toolchain's own clang is built for that toolchain's host targets, and the
  /// Windows 6.3.3 one fast-fails on an Xcode 26 sysroot before it prints
  /// anything at all. [name] selects `clang` or `clang++`.
  Future<String> resolveDarwinClang(
    String sysroot, {
    String name = 'clang',
    Future<CapturedProcess> Function(String, List<String>)? runProcess,
  }) async {
    // An explicit CC/CXX override takes precedence over the PATH search
    // below — this matters on systems (e.g. Nix) where a stray system
    // compiler sits ahead of the intended one on PATH.
    final envVar = name == 'clang++' ? 'CXX' : 'CC';
    final override = runner.environmentValue(
      runner.effectiveEnvironment,
      envVar,
    );
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
    final candidates = await runner.whichAll(name, extraDirectories: searched);
    final ordered = [
      ...candidates.where((path) => !_besideSwift(path)),
      ...candidates.where(_besideSwift),
    ];

    final minimum = minimumClangForSdk(sysroot);
    final rejected = <String>[];
    String? tooOld;
    for (final candidate in ordered) {
      final failure = await probeDarwinDriver(
        candidate,
        sysroot: sysroot,
        runProcess: runProcess,
      );
      if (failure != null) {
        log.logTrace('$name: skipping $candidate — $failure');
        rejected.add('  $candidate\n    $failure');
        continue;
      }
      final age = await clangTooOldForSdk(
        candidate,
        minimum: minimum,
        runProcess: runProcess,
      );
      if (age == null) return candidate;
      log.logTrace('$name: deprioritizing $candidate — $age');
      tooOld ??= candidate;
    }
    // A compiler older than the SDK's libc++ still builds plain C and
    // Objective-C, so keep using it rather than failing outright.
    if (tooOld != null) {
      if (_warnedOldClang.add(tooOld)) {
        log.logWarn(
          'Using $tooOld: '
          '${await clangTooOldForSdk(tooOld, minimum: minimum, runProcess: runProcess)}',
        );
      }
      return tooOld;
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

  /// Oldest clang major the SDK's libc++ headers accept, or null when the SDK
  /// has no recognizable libc++.
  ///
  /// libc++ supports the two latest clang releases before its own, so the
  /// libc++ 21 shipped with Xcode 26 needs clang 19 (it calls builtins such as
  /// `__builtin_clzg` that older compilers do not have).
  int? minimumClangForSdk(String sysroot) {
    final config = host.fileSystem.file(
      host.paths.context.join(
        sysroot,
        'usr',
        'include',
        'c++',
        'v1',
        '__config',
      ),
    );
    try {
      final match = _libcxxVersion.firstMatch(config.readAsStringSync());
      if (match == null) return null;
      return int.parse(match.group(1)!) ~/ 10000 - 2;
    } on FileSystemException {
      return null;
    }
  }

  final RegExp _libcxxVersion = RegExp(r'#\s*define\s+_LIBCPP_VERSION\s+(\d+)');

  /// Why [clang] is too old for an SDK whose libc++ needs clang [minimum], or
  /// null when it is new enough (or its version cannot be told).
  Future<String?> clangTooOldForSdk(
    String clang, {
    required int? minimum,
    Future<CapturedProcess> Function(String, List<String>)? runProcess,
  }) async {
    if (minimum == null) return null;
    final major = await clangMajorVersion(clang, runProcess: runProcess);
    if (major == null || major >= minimum) return null;
    return 'clang $major is older than the clang $minimum the Darwin SDK '
        'libc++ headers require, so C++ sources will not compile. Install '
        'clang $minimum or newer and put it on PATH, or set CC/CXX.';
  }

  /// Major version of an LLVM [clang], or null when it cannot be told.
  ///
  /// Apple clang numbers its releases differently and always matches the
  /// SDK it ships with, so it is reported as unknown rather than too old.
  Future<int?> clangMajorVersion(
    String clang, {
    Future<CapturedProcess> Function(String, List<String>)? runProcess,
  }) async {
    if (_clangVersions.containsKey(clang)) return _clangVersions[clang];
    int? major;
    try {
      final result = await (runProcess ?? runner.run)(clang, ['--version']);
      final output = '${result.stdout}\n${result.stderr}';
      if (!output.contains('Apple clang')) {
        final match = _clangVersion.firstMatch(output);
        if (match != null) major = int.parse(match.group(1)!);
      }
    } on Object catch (error) {
      log.logTrace('clang: $clang --version failed: $error');
    }
    return _clangVersions[clang] = major;
  }

  final RegExp _clangVersion = RegExp(r'clang version (\d+)\.');

  final Map<String, int?> _clangVersions = {};

  final Set<String> _warnedOldClang = {};

  String get _installClangHint => locations.clangInstallationHint;

  /// Why [clang] cannot be pointed at a Darwin [sysroot], or null when it can.
  ///
  /// `-###` makes the driver do all of its Darwin work — resolving the
  /// toolchain, reading the SDK settings, computing the deployment target —
  /// and then print the commands instead of running any of them, so the probe
  /// costs one process and writes nothing. A driver that dies there dies on
  /// every real compile too.
  Future<String?> probeDarwinDriver(
    String clang, {
    required String sysroot,
    Future<CapturedProcess> Function(String, List<String>)? runProcess,
  }) async {
    final key = '$clang\u0000$sysroot';
    final cached = _darwinDrivers[key];
    if (cached != null) return cached.isEmpty ? null : cached;

    final missing = host.paths.context.join(
      host.paths.temporaryRoot,
      'xcross-clang-probe',
      'probe.c',
    );
    final CapturedProcess result;
    try {
      result = await (runProcess ?? runner.run)(clang, [
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
      return _rememberDarwinDriver(key, 'could not be run: $error');
    }

    // A missing input file is expected and says nothing about the driver, so
    // only an outright crash disqualifies a candidate.
    if (runner.crashed(result.exitCode)) {
      return _rememberDarwinDriver(
        key,
        'crashed on a Darwin driver run: '
        '${runner.describeExitCode(result.exitCode)}',
      );
    }
    return _rememberDarwinDriver(key, null);
  }

  String? _rememberDarwinDriver(String clang, String? failure) {
    _darwinDrivers[clang] = failure ?? '';
    return failure;
  }

  /// Probe verdicts by clang path; the empty string means "usable".
  final Map<String, String> _darwinDrivers = {};

  /// Probe verdicts by linker path; the empty string means "usable".
  final Map<String, String> _iosSupport = {};

  final RegExp _unsupportedIosLink = RegExp(
    'does not support linking for platform|unknown platform|'
    'missing or unsupported -arch',
    caseSensitive: false,
  );

  /// PATH filter for [resolveLd64Lld] and the `xcross setup` requirement check.
  bool usableLd64Lld(String path) => !runner.isSwiftlyProxy(path);

  bool _besideSwift(String path) {
    final dir = host.paths.context.dirname(path);
    return host.fileSystem
        .file(host.paths.context.join(dir, host.paths.executableName('swift')))
        .existsSync();
  }
}
