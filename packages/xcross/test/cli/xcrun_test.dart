import 'dart:io';

import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../bin/xcrun.dart' as xcrun;

void main() {
  test('falls back without a sidecar or a supported sibling tool', () {
    final directory = Directory.systemTemp.createTempSync('xcross-xcrun-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final executable = p.join(directory.path, 'xcrun.exe');
    expect(
      xcrun.xcrunShimResponse(const [
        '--show-sdk-path',
      ], executable: executable),
      isNull,
    );
    File('$executable.sdk').writeAsStringSync('/sdk');
    File(p.join(directory.path, 'arbitrary.exe')).writeAsStringSync('');
    expect(
      xcrun.xcrunShimResponse(const [
        '--find',
        'arbitrary',
      ], executable: executable),
      isNull,
    );
    expect(
      xcrun.xcrunShimResponse(const [
        '--find',
        'clang',
      ], executable: executable),
      isNull,
    );
  });
  test('answers its own version without an SDK sidecar', () {
    final directory = Directory.systemTemp.createTempSync('xcross-xcrun-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final executable = p.join(directory.path, 'xcrun.exe');
    expect(
      xcrun.xcrunShimResponse(const ['--version'], executable: executable),
      'xcrun version ${xcrun.xcrunCompatVersion}.',
    );
    expect(
      xcrun.xcrunShimResponse(const ['-version'], executable: executable),
      'xcrun version ${xcrun.xcrunCompatVersion}.',
    );
  });
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
    final directory = Directory.systemTemp.createTempSync('xcross-xcrun-exit-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final script = File(p.join(directory.path, 'exit.dart'))
      ..writeAsStringSync("import 'dart:io'; void main() => exit(37);");
    final child = await Process.start(Platform.resolvedExecutable, [
      script.path,
    ]);
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

  test('preserves lowercase Windows compiler shim filenames', () async {
    final directory = await Directory.systemTemp.createTemp('xcross-xcrun-');
    try {
      final executable = File(
        '${directory.path}${Platform.pathSeparator}xcrun.exe',
      )..writeAsStringSync('');
      final platform = p.join(directory.path, 'iPhoneOS.platform');
      final sdk = p.join(platform, 'Developer', 'SDKs', 'iPhoneOS26.5.sdk');
      File('${executable.path}.sdk').writeAsStringSync(sdk);
      expect(
        xcrun.xcrunShimResponse(const [
          '--show-sdk-path',
        ], executable: executable.path),
        sdk,
      );
      final clang = File('${directory.path}${Platform.pathSeparator}clang.exe')
        ..writeAsStringSync('');

      expect(
        xcrun.xcrunShimResponse(const [
          '--find',
          'clang',
        ], executable: executable.path),
        clang.path,
      );
      expect(
        xcrun.xcrunShimResponse(const [
          '--version',
        ], executable: executable.path),
        'xcrun version ${xcrun.xcrunCompatVersion}.',
      );
      expect(
        xcrun.xcrunShimResponse(const [
          '--sdk',
          'iphoneos',
          'clang',
          '--version',
        ], executable: executable.path),
        isNull,
        reason: 'clang --version must reach the selected compiler',
      );
      for (final probe in ['--show-sdk-path', '--show-sdk-platform-path']) {
        expect(
          xcrun.xcrunShimResponse([
            '--sdk',
            'iphoneos',
            'clang',
            probe,
          ], executable: executable.path),
          isNull,
          reason: '$probe belongs to clang after tool selection',
        );
      }
      expect(
        xcrun.xcrunShimResponse(const [
          '--sdk',
          'iphoneos',
          '--show-sdk-platform-path',
        ], executable: executable.path),
        platform,
      );
      for (final arguments in [
        ['--sdk', 'macosx', '--show-sdk-path'],
        ['--sdk=iphonesimulator', '--show-sdk-platform-path'],
      ]) {
        expect(
          () => xcrun.xcrunShimResponse(arguments, executable: executable.path),
          throwsFormatException,
        );
      }
      expect(
        xcrun.xcrunShimResponse(const [
          '--sdk=iphoneos',
          '--show-sdk-path',
        ], executable: executable.path),
        sdk,
      );
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('rejects unavailable SDKs before resolving a tool', () async {
    expect(
      await xcrun.runXcrun(const [
        '--sdk=macosx',
        '--find',
        'clang',
      ], sdk: DarwinSdk('/unused')),
      1,
    );
  });

  test('forwards child flags unchanged without a sidecar', () async {
    final forwarded = <String>[];
    for (final probe in [
      '--show-sdk-path',
      '--show-sdk-platform-path',
      '--sdk=macosx',
      '--find',
    ]) {
      expect(
        await xcrun.runXcrun(
          ['clang', probe],
          sdk: DarwinSdk('/unused'),
          findOnPath: (_) async => '/fake/clang',
          runTool: (tool, arguments) async {
            expect(tool, '/fake/clang');
            forwarded.addAll(arguments);
            return 37;
          },
        ),
        37,
      );
    }
    expect(forwarded, [
      '--show-sdk-path',
      '--show-sdk-platform-path',
      '--sdk=macosx',
      '--find',
    ]);
  });
}
