import 'package:cli_kit/src/host_paths.dart';
import 'package:test/test.dart';

void main() {
  // `windows: true` everywhere, so the Win32 form is covered from any host.
  String long(String path) => HostPaths.long(path, windows: true);

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

  test('leaves paths alone off Windows', () {
    expect(HostPaths.long('/usr/lib/x', windows: false), '/usr/lib/x');
    expect(HostPaths.long('relative/x', windows: false), 'relative/x');
  });
}
