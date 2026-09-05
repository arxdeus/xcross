import 'dart:convert';

import 'package:cli_kit/cli_kit.dart';

/// Requirements from the README table, plus the Swift toolchain's own build
/// dependencies, named the way each distro family spells them. Swift and
/// Flutter stay manual everywhere.
///
/// The lists are deliberately neither one-to-one nor minimal:
///
/// * Distros that ship headers inside the main package (Arch) or that never
///   versioned their `-devel` packages (Fedora) need fewer entries.
/// * Names that only some releases of a family have — Ubuntu keeps `usbip`
///   inside `linux-tools-common` while Debian ships it standalone — are all
///   listed; [LinuxPackageManager.installAttempts] drops the ones the host has
///   never heard of.
/// * The unversioned `gcc`/`g++` metapackages stand in for Debian's
///   `libstdc++-N-dev`/`libgcc-N-dev`, whose N differs per release.
const _aptPackages = [
  'clang',
  'lld',
  'llvm',
  'python3',
  'python3-pip',
  'python3-venv',
  'usbmuxd',
  'usbutils',
  'libimobiledevice-utils',
  'linux-tools-common',
  'usbip',
  'pkg-config',
  'zlib1g-dev',
  'libpython3-dev',
  'gcc',
  'g++',
  'libxml2-dev',
  'libncurses-dev',
  'libz3-dev',
  'gnupg2',
  'libc6-dev',
  'libcurl4-openssl-dev',
];

const _dnfPackages = [
  'clang',
  'lld',
  'llvm',
  'python3',
  'python3-pip',
  'python3-devel',
  'usbmuxd',
  'usbutils',
  'libimobiledevice-utils',
  'usbip',
  'pkgconf-pkg-config',
  'zlib-devel',
  'libstdc++-devel',
  'libxml2-devel',
  'ncurses-devel',
  'z3-devel',
  'gnupg2',
  'glibc-devel',
  'libcurl-devel',
  'gcc',
  'gcc-c++',
];

const _pacmanPackages = [
  'clang',
  'lld',
  'llvm',
  'python',
  'python-pip',
  'usbmuxd',
  'usbutils',
  'libimobiledevice',
  'usbip',
  'pkgconf',
  'zlib',
  'libxml2',
  'ncurses',
  'z3',
  'gnupg',
  'glibc',
  'curl',
  'gcc',
];

/// A supported Linux package manager, with the package names and command
/// shapes `xcross setup` needs from it.
enum LinuxPackageManager {
  apt(
    executable: 'apt-get',
    packages: _aptPackages,
    pipxPackage: 'pipx',
    manualCommand: 'sudo apt install',
  ),
  dnf(
    executable: 'dnf',
    packages: _dnfPackages,
    pipxPackage: 'pipx',
    manualCommand: 'sudo dnf install',
  ),
  pacman(
    executable: 'pacman',
    packages: _pacmanPackages,
    pipxPackage: 'python-pipx',
    manualCommand: 'sudo pacman -S',
  );

  const LinuxPackageManager({
    required this.executable,
    required this.packages,
    required this.pipxPackage,
    required this.manualCommand,
  });

  /// Binary looked up on PATH to detect this manager.
  final String executable;

  /// Every requirement installable by this manager.
  final List<String> packages;

  /// Distro package that provides the `pipx` command.
  final String pipxPackage;

  /// Prefix of the copy-pasteable manual install command.
  final String manualCommand;

  /// Managers whose executable is on PATH, in preference order.
  static Future<List<LinuxPackageManager>> detect() async {
    final found = <LinuxPackageManager>[];
    for (final manager in values) {
      if (await ProcessRunner.which(manager.executable) != null) {
        found.add(manager);
      }
    }
    return found;
  }

  String manualHint([List<String>? subset]) =>
      'Install manually:\n    $manualCommand ${(subset ?? packages).join(' ')}';

  /// Ordered install command vectors to try for [wanted], most tolerant first.
  ///
  /// Package sets differ across releases of the same family, and only dnf can
  /// be told to shrug that off (`--skip-unavailable` in dnf5, `strict=0` in
  /// dnf4). apt and pacman both refuse the whole transaction over one unknown
  /// target, so those names are filtered out beforehand.
  Future<List<List<String>>> installAttempts(List<String> wanted) async {
    final sudo = await Sudo.resolve();
    List<String> command(List<String> args) => [
      if (sudo != null) sudo,
      ...args,
    ];

    switch (this) {
      case LinuxPackageManager.apt:
        final known = await _known(wanted);
        return [
          command(['apt-get', 'install', '-y', ...known]),
          // A mirror that has already rotated to a newer point release still
          // advertises the old .deb in this host's cached index, and apt
          // aborts the whole transaction on that single 404
          // ("Failed to fetch … 404 Not Found"). Refreshing the index first
          // is the documented fix ("maybe run apt-get update"), and it is
          // exactly what the retry does — cheap, and only reached after a
          // real failure.
          command(['sh', '-c', _aptUpdateThenInstall(known)]),
        ];
      case LinuxPackageManager.dnf:
        return [
          command(['dnf', 'install', '-y', '--skip-unavailable', ...wanted]),
          command(['dnf', 'install', '-y', '--setopt=strict=0', ...wanted]),
          command(['dnf', 'install', '-y', ...wanted]),
        ];
      case LinuxPackageManager.pacman:
        final known = await _known(wanted);
        return [
          command(['pacman', '-S', '--needed', '--noconfirm', ...known]),
          // A stale sync database is the usual reason the plain form fails.
          command(['pacman', '-Syu', '--needed', '--noconfirm', ...known]),
        ];
    }
  }

  /// Versioned `lld-<N>` packages this host's apt index offers, newest
  /// first. Empty for other managers (their default `lld` is current) and
  /// when the index cannot be read.
  ///
  /// Debian and Ubuntu keep a stale `lld` as the default while newer
  /// toolchains sit beside it in the same archive — Ubuntu 24.04 pairs lld
  /// 18 with `lld-19` in noble-updates.
  Future<List<String>> availableVersionedLld() async {
    if (this != LinuxPackageManager.apt) return const [];
    final Set<String> indexed;
    try {
      final result = await ProcessRunner.run(
        await ProcessRunner.locateTool('apt-cache'),
        ['pkgnames', 'lld-'],
      );
      indexed = const LineSplitter()
          .convert(result.stdout)
          .map((line) => line.trim())
          .toSet();
    } on Object catch (e) {
      Log.logTrace('[$name] package index query failed ($e)');
      return const [];
    }
    final versions = <int, String>{};
    for (final name in indexed) {
      final match = _versionedLld.firstMatch(name);
      if (match != null) versions[int.parse(match.group(1)!)] = name;
    }
    return [
      for (final version in versions.keys.toList()..sort((a, b) => b - a))
        versions[version]!,
    ];
  }

  static final _versionedLld = RegExp(r'^lld-(\d+)$');

  /// [wanted] minus the names this host's package index has never heard of.
  ///
  /// `apt-cache pkgnames` lists every known binary package (including virtual
  /// ones), and `pacman -Si` reports each miss as
  /// `error: package 'x' was not found` on stderr while still printing the
  /// hits — so one query classifies the whole list either way.
  Future<List<String>> _known(List<String> wanted) async {
    final Set<String?> missing;
    // The query is an optimisation — it only trims names this host cannot
    // install anyway. A missing query binary must therefore degrade to "keep
    // every name" rather than abort setup with a raw ProcessException.
    try {
      switch (this) {
        case LinuxPackageManager.apt:
          final result = await ProcessRunner.run(
            await ProcessRunner.locateTool('apt-cache'),
            ['pkgnames'],
          );
          final indexed = const LineSplitter()
              .convert(result.stdout)
              .map((line) => line.trim())
              .toSet();
          if (indexed.isEmpty) return wanted;
          missing = wanted.where((name) => !indexed.contains(name)).toSet();
        case LinuxPackageManager.pacman:
          final result = await ProcessRunner.run(
            await ProcessRunner.locateTool('pacman'),
            ['-Si', ...wanted],
          );
          missing = _pacmanNotFoundPattern
              .allMatches(result.stderr)
              .map((match) => match.group(1))
              .toSet();
        case LinuxPackageManager.dnf:
          return wanted;
      }
    } on Object catch (e) {
      Log.logTrace('[$name] package index query failed ($e); keeping all');
      return wanted;
    }
    if (missing.isEmpty) return wanted;

    final known = wanted.where((name) => !missing.contains(name)).toList();
    // Every name unknown means the query itself failed (no package index, no
    // network); let the package manager report that properly instead of
    // running with an empty target list.
    if (known.isEmpty) return wanted;

    Log.logTrace('[$name] unknown packages skipped: ${missing.join(', ')}');
    return known;
  }

  static final _pacmanNotFoundPattern = RegExp(
    "package '([^']+)' was not found",
  );

  /// `apt-get update && apt-get install -y …`, quoted for `sh -c`.
  ///
  /// One shell command, not two vectors: the update must run under the same
  /// privilege escalation as the install that follows it.
  static String _aptUpdateThenInstall(List<String> packages) {
    final quoted = packages.map((name) => "'$name'").join(' ');
    return 'apt-get update && apt-get install -y $quoted';
  }
}
