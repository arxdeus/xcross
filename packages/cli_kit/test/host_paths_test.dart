import 'package:cli_kit/cli_kit.dart';
import 'package:test/test.dart';

void main() {
  final windows = WindowsHost();
  String long(String path) => windows.paths.ioPath(path);

  group('HostPaths.long on Windows', () {
    test('prefixes an absolute path so it can exceed MAX_PATH', () {
      expect(long(r'C:\a\b'), r'\\?\C:\a\b');
    });

    test('normalizes before prefixing', () {
      expect(long(r'C:\a\b\..\c'), r'\\?\C:\a\c');
    });

    test('gives a UNC share the UNC form of the prefix', () {
      expect(long(r'\\server\share\x'), r'\\?\UNC\server\share\x');
    });

    test('is idempotent, so callers may apply it more than once', () {
      for (final path in [r'C:\a\b', r'\\server\share\x']) {
        final once = long(path);
        expect(long(once), once, reason: path);
      }
    });
  });

  test('POSIX paths anchor relative names without rewriting traversal', () {
    expect(LinuxHost().paths.ioPath('/usr/lib/x'), '/usr/lib/x');
    final paths = MacOSHost(currentDirectory: '/snapshot').paths;
    expect(paths.ioPath('relative/x'), '/snapshot/relative/x');
    expect(paths.ioPath('link/../x'), '/snapshot/link/../x');
    expect(paths.ioPath('/absolute/link/../x'), '/absolute/link/../x');
  });
}
