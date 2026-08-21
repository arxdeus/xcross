import 'package:test/test.dart';
import 'package:xcross/src/cli/basic/internal/linux_package_manager.dart';

void main() {
  group('LinuxPackageManager.apt install attempts', () {
    test('retries with an index refresh after a plain install', () async {
      final attempts = await LinuxPackageManager.apt.installAttempts(const [
        'curl',
      ]);
      expect(attempts, hasLength(2));
      expect(attempts.first.join(' '), contains('apt-get install -y'));

      // A stale index advertising a .deb the mirror already rotated away
      // makes apt abort the whole transaction with a bare 404; the retry
      // refreshes it under the same escalation before installing again.
      final retry = attempts.last;
      expect(retry, contains('sh'));
      expect(retry.last, startsWith('apt-get update && apt-get install -y'));
      expect(retry.last, contains("'curl'"));
    });

    test('keeps every name when the package index cannot be queried', () async {
      // apt-cache is absent on non-Debian hosts (and in minimal containers);
      // setup must still produce a usable command instead of throwing.
      final attempts = await LinuxPackageManager.apt.installAttempts(const [
        'curl',
        'llvm',
      ]);
      expect(attempts.first, containsAllInOrder(['curl', 'llvm']));
    });

    test('pacman and dnf keep their own retry shapes', () async {
      final dnf = await LinuxPackageManager.dnf.installAttempts(const ['llvm']);
      expect(dnf, hasLength(3));
      expect(dnf.first.join(' '), contains('--skip-unavailable'));

      final pacman = await LinuxPackageManager.pacman.installAttempts(const [
        'llvm',
      ]);
      expect(pacman, hasLength(2));
      expect(pacman.last.join(' '), contains('-Syu'));
    });
  });
}
