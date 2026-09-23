import 'dart:io';

import 'package:path/path.dart' as p;

/// Filesystem path forms the host's own APIs need.
abstract final class HostPaths {
  /// [path] in the form Win32 needs to exceed `MAX_PATH`, unchanged elsewhere.
  ///
  /// Windows caps most path APIs at 260 characters unless the path is
  /// absolute and carries the extended-length prefix (`\\?\`, or `\\?\UNC\`
  /// for a share). Directory enumeration is the usual casualty, since Win32
  /// appends `\*` to the directory before opening it.
  ///
  /// Paths that already carry the prefix are returned unchanged, so this is
  /// safe to apply more than once. [windows] overrides the host check, which
  /// is what lets the Win32 form be tested from any machine.
  static String long(String path, {bool? windows}) {
    if (!(windows ?? Platform.isWindows)) return path;
    final absolute = p.windows.normalize(p.windows.absolute(path));
    if (absolute.startsWith(_prefix)) return absolute;
    // A UNC path (\\server\share) becomes \\?\UNC\server\share.
    if (absolute.startsWith(r'\\')) {
      return '$_uncPrefix${absolute.substring(2)}';
    }
    return '$_prefix$absolute';
  }

  static const _prefix = r'\\?\';
  static const _uncPrefix = r'\\?\UNC\';
}
