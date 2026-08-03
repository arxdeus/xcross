import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('release publishes only xcross artifacts and keeps attribution', () {
    final workflow = File('.github/workflows/release.yml').readAsStringSync();

    for (final expected in [
      'native/signing/ZSIGN_LICENSE.txt',
      'dist/THIRD_PARTY_LICENSES/zsign.txt',
      "'THIRD_PARTY_LICENSES/zsign.txt'",
      'packages/apple_developer_kit/ADI_LICENSE',
      'dist/THIRD_PARTY_LICENSES/provision-dart.txt',
      "'THIRD_PARTY_LICENSES/provision-dart.txt'",
      'dart analyze',
      'dart test packages/cli_kit',
      'dart test packages/apple_developer_kit',
      'dart test packages/darwin_sdk_kit',
      'dart test packages/dart_mobile_device',
      'dart test packages/xcross_flutter',
      'dart test packages/xcross_dap',
      'dart build cli',
      "if: startsWith(github.ref, 'refs/tags/')",
      r'gh release create "$tag"',
      'dist/xcross-linux-x64.tar.gz',
      'dist/xcross-linux-arm64.tar.gz',
      'dist/xcross-windows-x64.zip',
      'native/signing/ZSIGN_LICENSE.txt',
      'bin/xcross.exe',
      'lib/sysv_abi_bridge.dll',
      'smoke/bin/xcross.exe --help',
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
      'xcross-linux-x64.tar.gz',
      'xcross-linux-arm64.tar.gz',
      'NOTICE="ZSIGN_LICENSE.txt"',
      r'tmp="$(mktemp -d)"',
      r'''trap 'rm -rf "$tmp"' EXIT HUP INT TERM''',
      r'download "$url" "$tmp/$asset"',
      r'download "$notice_url" "$tmp/$NOTICE"',
      r'tar -C "$tmp" -xzf "$tmp/$asset"',
      r'install -m 0755 "$tmp/bin/xcross" "$target"',
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
