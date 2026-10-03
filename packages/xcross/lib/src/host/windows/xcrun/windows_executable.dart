import 'package:path/path.dart' as p;

String normalizeWindowsExecutableExtension(String path) =>
    const WindowsExecutable().normalize(path);

final class WindowsExecutable {
  const WindowsExecutable();

  String normalize(String path) {
    if (p.windows.extension(path).toLowerCase() != '.exe') return path;
    return '${p.windows.withoutExtension(path)}.exe';
  }

  bool acceptDartLauncher(String path) => const {
    'dart.exe',
    'dart.bat',
    'dart.cmd',
  }.contains(p.windows.basename(path).toLowerCase());
}
