import 'dart:io';

import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:test/test.dart';

import '../../bin/xcrun.dart' as xcrun;

void main() {
  test('rejects an invocation without a tool', () async {
    expect(await xcrun.runXcrun(const []), 1);
  });

  test('answers the --version probe without an SDK', () async {
    expect(await xcrun.runXcrun(const ['--version']), 0);
  });

  test('normalizes PATHEXT uppercase .EXE for native_toolchain_c', () {
    expect(
      xcrun.normalizeWindowsExecutableExtension(
        r'C:\Temp\xcross-tools\clang.EXE',
        windows: true,
      ),
      r'C:\Temp\xcross-tools\clang.exe',
    );
    expect(
      xcrun.normalizeWindowsExecutableExtension(
        r'C:\Temp\xcross-tools\ar.EXE',
        windows: true,
      ),
      r'C:\Temp\xcross-tools\ar.exe',
    );
    expect(
      xcrun.normalizeWindowsExecutableExtension(
        '/tools/clang.EXE',
        windows: false,
      ),
      '/tools/clang.EXE',
    );
  });

  test('returns the exact streamed child exit code', () async {
    final child = await Process.start('sh', const ['-c', 'exit 37']);
    expect(
      await xcrun.runResolvedTool(
        '/ignored',
        const [],
        start: (_, _) async => child,
      ),
      37,
    );
  });

  test('prefers build shims on PATH for known Apple tools', () async {
    final sdk = DarwinSdk('/unused');
    for (final tool in const ['clang', 'otool']) {
      final shim = '/build/shims/$tool';
      expect(
        await xcrun.runXcrun(
          ['--find', tool],
          sdk: sdk,
          findOnPath: (name) async => name == tool ? shim : null,
        ),
        0,
      );
    }
  });
}
