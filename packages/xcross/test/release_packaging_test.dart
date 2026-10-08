import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

final String _repoRoot = Directory.fromUri(
  Isolate.resolvePackageUriSync(Uri.parse('package:xcross/'))!,
).parent.parent.parent.path;

void main() {
  test('installer installs xcross plus its required license notice', () {
    final installer = File('$_repoRoot/install.sh').readAsStringSync();

    for (final expected in [
      'xcross-linux-x64.tar.gz',
      'xcross-linux-arm64.tar.gz',
      'LICENSE_ASSET="ADI_LICENSE"',
      r'staging_dir="$(mktemp -d)"',
      r'''trap 'rm -rf "$staging_dir"' EXIT HUP INT TERM''',
      r'download "$base_url/$archive_name" "$staging_dir/$archive_name"',
      r'download "$base_url/$LICENSE_ASSET" "$staging_dir/$LICENSE_ASSET"',
      r'tar -C "$staging_dir" -xzf "$staging_dir/$archive_name"',
      r'install -m 0755 "$staging_dir/bin/$BINARY_NAME" "$installed_binary"',
      r'install -m 0755 "$staging_dir/bin/xcrun" "$INSTALL_DIR/xcrun"',
      r'install -m 0644 "$staging_dir/$LICENSE_ASSET" "$installed_license"',
      r'"$installed_binary" --help',
      '--local',
      r'(cd "$script_dir" && dart pub get)',
      'tool/build_xcross.dart',
      r'cp -a "$bundle_dir/bin/." "$staging_dir/bin/"',
      r'cp -a "$bundle_dir/lib/." "$staging_dir/lib/"',
    ]) {
      expect(installer, contains(expected));
    }
    for (final removed in ['zsign', 'ZSIGN', 'XCROSS_ZSIGN_PATH']) {
      expect(installer, isNot(contains(removed)));
    }
  });

  test('Windows installer installs release zip under LOCALAPPDATA', () {
    final installer = File('$_repoRoot/install.ps1').readAsStringSync();

    for (final expected in [
      'xcross-windows-x64.zip',
      'xcross-windows-arm64.zip',
      'PROCESSOR_ARCHITEW6432',
      'OSArchitecture',
      r"$archSources -contains 'ARM64'",
      r'$Asset = $Assets[$arch]',
      'LOCALAPPDATA',
      'sysv_abi_bridge.dll',
      r'bin\xcross.exe',
      r'bin\xcrun.exe',
      '--help',
      r"Join-Path $env:LOCALAPPDATA 'xcross'",
      'SetEnvironmentVariable',
    ]) {
      expect(installer, contains(expected));
    }
    for (final removed in ['zsign.exe', 'XCROSS_ZSIGN_PATH']) {
      expect(installer, isNot(contains(removed)));
    }
    expect(installer, isNot(contains("-ne 'AMD64'")));
    expect(installer, isNot(contains('x64-only')));
  });

  test('release workflow builds, attests and publishes every archive', () {
    final workflow = File(
      '$_repoRoot/.github/workflows/release.yml',
    ).readAsStringSync();

    for (final expected in [
      'runner: windows-2022',
      'asset: xcross-windows-x64',
      'cli-dir: windows_x64',
      'runner: windows-11-arm',
      'asset: xcross-windows-arm64',
      'cli-dir: windows_arm64',
      r'architecture: ${{ matrix.architecture }}',
      r'MSVC_ARCHITECTURE: ${{ matrix.architecture }}',
      'Microsoft.VisualStudio.Component.VC.Tools.ARM64',
    ]) {
      expect(workflow, contains(expected));
    }
    for (final asset in [
      'xcross-linux-x64.tar.gz',
      'xcross-linux-arm64.tar.gz',
      'xcross-windows-x64.zip',
      'xcross-windows-arm64.zip',
    ]) {
      expect(
        RegExp(RegExp.escape(asset)).allMatches(workflow).length,
        greaterThanOrEqualTo(3),
        reason: '$asset must be attested, checksummed and uploaded',
      );
      expect(workflow, contains('dist/$asset'));
    }
    expect(workflow, isNot(contains('build/cli/windows_x64/bundle')));
  });
}
