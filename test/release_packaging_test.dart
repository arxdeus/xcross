import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('Linux release builds and publishes pinned zsign binaries', () {
    final workflow = File('.github/workflows/release.yml').readAsStringSync();

    for (final expected in [
      'd6e929c97b5b564c2cc1f82afe226a44da7149a0',
      'repository: zhlynn/zsign',
      'sudo apt-get install -y g++ pkg-config libssl-dev',
      'make -C zsign/build/linux',
      'dist/zsign-linux-x64',
      'dist/zsign-linux-arm64',
    ]) {
      expect(workflow, contains(expected));
    }
    expect(
      workflow,
      contains("if: startsWith(github.ref, 'refs/tags/')"),
      reason: 'workflow_dispatch must build without publishing',
    );
  });

  test('installer downloads and verifies xcross and matching zsign', () {
    final installer = File('install.sh').readAsStringSync();

    for (final expected in [
      'zsign-linux-x64',
      'zsign-linux-arm64',
      r'tmp="$(mktemp -d)"',
      r"""trap 'rm -rf "$tmp"'""",
      r'"$target" --help',
      r'"$zsign_target" -h',
    ]) {
      expect(installer, contains(expected));
    }
  });
}
