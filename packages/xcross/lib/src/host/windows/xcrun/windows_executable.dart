import 'package:path/path.dart' as p;

String normalizeWindowsExecutableExtension(String path) {
  if (p.windows.extension(path).toLowerCase() != '.exe') return path;
  return '${p.windows.withoutExtension(path)}.exe';
}
