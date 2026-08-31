import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/version.dart';

/// Where an installed xcross keeps its executable and its native libraries.
///
/// Both installers produce the same shape — `<prefix>/bin/xcross` next to
/// `<prefix>/lib/*` — even though `install.sh` splits it across
/// `/usr/local/bin` and `/usr/local/lib` while `install.ps1` keeps one
/// self-contained directory. The binary itself resolves its libraries as
/// `../lib`, so that relationship is the only rule needed here.
@immutable
final class InstallLayout {
  const InstallLayout({
    required this.binaryPath,
    required this.binDir,
    required this.libDir,
  });

  /// Absolute path of the installed executable, with symlinks resolved.
  final String binaryPath;

  /// Directory holding [binaryPath].
  final String binDir;

  /// Sibling directory holding the native libraries.
  final String libDir;

  /// Resolves the layout of the currently running executable.
  factory InstallLayout.resolve() =>
      InstallLayout.forExecutable(Platform.resolvedExecutable);

  /// Resolves the layout for [executable].
  ///
  /// Throws [XcrossError] when the executable is the Dart VM (a `dart run`
  /// checkout) or when the sibling `lib/` directory is missing, because a
  /// layout we do not recognise must not be half-overwritten.
  factory InstallLayout.forExecutable(String executable) {
    final resolved = _resolveSymlinks(executable);
    final name = p.basenameWithoutExtension(resolved).toLowerCase();
    if (name == 'dart' || name == 'dartaotruntime') {
      throw XcrossError(
        'this xcross was built from a source checkout '
        '(${XcrossVersion.current}); update only works on a binary installed '
        'by install.sh or install.ps1.',
      );
    }

    final binDir = p.dirname(resolved);
    final libDir = p.join(p.dirname(binDir), 'lib');
    // Merely existing is not enough: `dart compile exe -o packages/xcross/bin/`
    // in a source checkout also produces a sibling `lib/`, and that one holds
    // the package's Dart sources.
    if (!_isNativeLibraryDirectory(libDir)) {
      throw XcrossError(
        'unrecognised xcross installation: expected a native library directory '
        'at $libDir (next to $binDir).\n'
        'Reinstall with install.sh or install.ps1, then retry.',
      );
    }

    return InstallLayout(binaryPath: resolved, binDir: binDir, libDir: libDir);
  }

  static bool _isNativeLibraryDirectory(String libDir) {
    try {
      final files = Directory(libDir).listSync().whereType<File>().toList();
      return files.isEmpty || files.any(_isNativeLibrary);
    } on FileSystemException {
      return false;
    }
  }

  /// Whether at least one native asset remains installed.
  ///
  /// An empty library directory is still a recognised installation so
  /// `xcross update` can repair it by downloading the release again.
  bool get hasNativeLibraries {
    try {
      return Directory(
        libDir,
      ).listSync().whereType<File>().any(_isNativeLibrary);
    } on FileSystemException {
      return false;
    }
  }

  static bool _isNativeLibrary(File file) =>
      _nativeLibrary.hasMatch(p.basename(file.path));

  static final _nativeLibrary = RegExp(r'\.(?:so|dll|dylib)(?:\.[0-9.]+)?$');

  /// A symlinked `xcross` on PATH must update the real file, not the link.
  static String _resolveSymlinks(String executable) {
    try {
      return File(executable).resolveSymbolicLinksSync();
    } on FileSystemException {
      return p.absolute(executable);
    }
  }

  /// Whether both target directories can be written without elevation.
  bool get isWritable => _isWritable(binDir) && _isWritable(libDir);

  static bool _isWritable(String directory) {
    final probe = File(p.join(directory, '.xcross-write-probe-$pid'));
    try {
      probe.writeAsStringSync('');
      probe.deleteSync();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  @override
  String toString() => 'InstallLayout(bin: $binDir, lib: $libDir)';
}
