import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('release publishes only xcross artifacts and keeps attribution', () {
    final workflow = File('.github/workflows/release.yml').readAsStringSync();

    for (final expected in [
      'native/signing/ZSIGN_LICENSE.txt',
      'dist/THIRD_PARTY_LICENSES/zsign.txt',
      "'THIRD_PARTY_LICENSES/zsign.txt'",
      'dart analyze',
      'dart test',
      "if: startsWith(github.ref, 'refs/tags/')",
      r'gh release create "$tag"',
      'dist/xcross-linux-x64',
      'dist/xcross-linux-arm64',
      'dist/xcross-windows-x64.zip',
      'native/signing/ZSIGN_LICENSE.txt',
      'xcross.exe --help',
    ]) {
      expect(workflow, contains(expected));
    }
    expect(
      workflow
          .split('\n')
          .where((line) => line.toLowerCase().contains('zsign'))
          .map((line) => line.trim()),
      orderedEquals([
        'native/signing/ZSIGN_LICENSE.txt `',
        'dist/THIRD_PARTY_LICENSES/zsign.txt',
        "'THIRD_PARTY_LICENSES/zsign.txt'",
        r'native/signing/ZSIGN_LICENSE.txt \',
      ]),
    );
    for (final removed in [
      'libssl-dev',
      'microsoft/setup-msbuild',
      'make -C',
      'msbuild ',
    ]) {
      expect(workflow, isNot(contains(removed)));
    }
  });

  test('installer installs xcross plus its required license notice', () {
    final installer = File('install.sh').readAsStringSync();

    for (final expected in [
      'xcross-linux-x64',
      'xcross-linux-arm64',
      'NOTICE="ZSIGN_LICENSE.txt"',
      r'tmp="$(mktemp -d)"',
      r'''trap 'rm -rf "$tmp"' EXIT HUP INT TERM''',
      r'download "$url" "$tmp/$asset"',
      r'download "$notice_url" "$tmp/$NOTICE"',
      r'install -m 0755 "$tmp/$asset" "$target"',
      r'install -m 0644 "$tmp/$NOTICE" "$notice_target"',
      r'"$target" --help',
    ]) {
      expect(installer, contains(expected));
    }
    for (final removed in ['zsign-linux', 'zsign.exe', 'XCROSS_ZSIGN_PATH']) {
      expect(installer, isNot(contains(removed)));
    }
  });
}
