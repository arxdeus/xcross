import 'dart:io';

import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../bin/xcrun.dart' as xcrun;

void main() {
  test(
    'simulator sidecar accepts generic exact and implicit simulator selection',
    () {
      final directory = Directory.systemTemp.createTempSync(
        'xcross-xcrun-simulator-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final executable = p.join(directory.path, 'xcrun.exe');
      final platform = p.join(directory.path, 'iPhoneSimulator.platform');
      final sdk = p.join(
        platform,
        'Developer',
        'SDKs',
        'iPhoneSimulator26.5.sdk',
      );
      File('$executable.sdk').writeAsStringSync(sdk);
      final clang = File(p.join(directory.path, 'clang.exe'))
        ..writeAsStringSync('');
      for (final selection in <List<String>>[
        [],
        ['--sdk', 'iphonesimulator'],
        ['--sdk=iphonesimulator'],
        ['--sdk', 'iphonesimulator26.5'],
        ['--sdk=IPHONESIMULATOR26.5'],
        ['--sdk=iphoneos', '--sdk', 'iphonesimulator'],
      ]) {
        expect(
          xcrun.xcrunShimResponse([
            ...selection,
            '--show-sdk-path',
          ], executable: executable),
          sdk,
        );
        expect(
          xcrun.xcrunShimResponse([
            ...selection,
            '--show-sdk-version',
          ], executable: executable),
          '26.5',
        );
        expect(
          xcrun.xcrunShimResponse([
            ...selection,
            '--show-sdk-platform-path',
          ], executable: executable),
          platform,
        );
        expect(
          xcrun.xcrunShimResponse([
            ...selection,
            '--find',
            'clang',
          ], executable: executable),
          clang.path,
        );
      }
      for (final rejected in [
        'iphoneos',
        'iphoneos26.5',
        'iphonesimulator26.4',
        'macosx',
        'iphonesimulatorbogus',
        '',
      ]) {
        expect(
          () => xcrun.xcrunShimResponse([
            '--sdk=$rejected',
            '--show-sdk-path',
          ], executable: executable),
          throwsFormatException,
        );
        expect(
          () => xcrun.xcrunShimResponse([
            '--sdk=$rejected',
            '--show-sdk-version',
          ], executable: executable),
          throwsFormatException,
        );
        expect(
          () => xcrun.findShimTool([
            '--sdk=$rejected',
            '--find',
            'clang',
          ], executable: executable),
          throwsFormatException,
        );
      }
      expect(
        () => xcrun.xcrunShimResponse(['--sdk'], executable: executable),
        throwsFormatException,
      );
    },
  );

  test(
    'Windows simulator sidecar path selects simulator even on another test host',
    () {
      final directory = Directory.systemTemp.createTempSync(
        'xcross-xcrun-windows-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final executable = p.join(directory.path, 'xcrun.exe');
      const sdk =
          r'C:\SDK\iPhoneSimulator.platform\Developer\SDKs\iPhoneSimulator26.5.sdk';
      File('$executable.sdk').writeAsStringSync(sdk);
      expect(
        xcrun.xcrunShimResponse([
          '--sdk=iphonesimulator',
          '--show-sdk-path',
        ], executable: executable),
        sdk,
      );
      expect(
        xcrun.xcrunShimResponse(['--show-sdk-version'], executable: executable),
        '26.5',
      );
      expect(
        xcrun.xcrunShimResponse([
          '--show-sdk-platform-path',
        ], executable: executable),
        r'C:\SDK\iPhoneSimulator.platform',
      );
      expect(
        () => xcrun.xcrunShimResponse([
          '--sdk=iphoneos',
          '--show-sdk-path',
        ], executable: executable),
        throwsFormatException,
      );
    },
  );

  test(
    'fallback honors simulator sidecar and rejects mismatched tool selection',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'xcross-xcrun-fallback-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final executable = p.join(directory.path, 'xcrun.exe');
      File(
        '$executable.sdk',
      ).writeAsStringSync('/isolated/iPhoneSimulator26.5.sdk');
      var lookups = 0;
      final forwarded = <String>[];
      for (final selection in <List<String>>[
        [],
        ['--sdk', 'iphonesimulator'],
        ['--sdk=iphonesimulator26.5'],
      ]) {
        expect(
          await xcrun.runXcrun(
            [...selection, 'clang', '--sdk=iphoneos'],
            sdk: DarwinSdk('/unused'),
            executable: executable,
            findOnPath: (_) async {
              lookups++;
              return '/tools/clang';
            },
            runTool: (_, arguments) async {
              forwarded.addAll(arguments);
              return 37;
            },
          ),
          37,
        );
      }
      expect(forwarded, List.filled(3, '--sdk=iphoneos'));
      expect(lookups, 3);
      for (final rejected in ['iphoneos', 'iphonesimulator26.4', 'macosx']) {
        expect(
          await xcrun.runXcrun(
            ['--sdk=$rejected', '--find', 'clang'],
            sdk: DarwinSdk('/unused'),
            executable: executable,
            findOnPath: (_) async {
              lookups++;
              return '/tools/clang';
            },
          ),
          1,
        );
      }
      expect(lookups, 3);
    },
  );

  test(
    'installed SDK probes select device by default and explicit simulator without sidecar',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'xcross-xcrun-probes-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final bundle = p.join(directory.path, 'bundle');
      final paths = <IosTarget, String>{};
      for (final target in IosTarget.values) {
        paths[target] = p.join(
          bundle,
          'Developer',
          'Platforms',
          '${target.platformName}.platform',
          'Developer',
          'SDKs',
          '${target.platformName}26.5.sdk',
        );
        Directory(paths[target]!).createSync(recursive: true);
      }
      final executable = p.join(directory.path, 'xcrun.exe');
      final script = File(p.join(directory.path, 'probe.dart'));
      final shim = File(
        p.join(
          Directory.current.path,
          'packages',
          'xcross',
          'bin',
          'xcrun.dart',
        ),
      );
      final shimFile = shim.existsSync()
          ? shim
          : File(p.join(Directory.current.path, 'bin', 'xcrun.dart'));
      script.writeAsStringSync("""
import 'dart:io';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import '${shimFile.uri}' as xcrun;
Future<void> main(List<String> args) async {
  exitCode = await xcrun.runXcrun(args, sdk: DarwinSdk(r'$bundle'), executable: r'$executable');
}
""");
      final packageConfig = p.fromUri(
        Platform.packageConfig ??
            p.join(Directory.current.path, '.dart_tool', 'package_config.json'),
      );
      final kernel = p.join(directory.path, 'probe.dill');
      final compile = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'kernel',
        '--packages=$packageConfig',
        script.path,
        '-o',
        kernel,
      ]);
      expect(
        compile.exitCode,
        0,
        reason: '${compile.stdout}\n${compile.stderr}',
      );
      Future<ProcessResult> probe(List<String> arguments) =>
          Process.run(Platform.resolvedExecutable, [kernel, ...arguments]);
      for (final target in IosTarget.values) {
        for (final selection in <List<String>>[
          if (target == IosTarget.device) [],
          ['--sdk', target.sdkName],
          ['--sdk=${target.sdkName}26.5'],
        ]) {
          final path = await probe([...selection, '--show-sdk-path']);
          expect(path.exitCode, 0, reason: path.stderr.toString());
          expect(path.stdout.toString().trim(), paths[target]);
          final version = await probe([...selection, '--show-sdk-version']);
          expect(version.exitCode, 0, reason: version.stderr.toString());
          expect(version.stdout.toString().trim(), '26.5');
          final platform = await probe([
            ...selection,
            '--show-sdk-platform-path',
          ]);
          expect(platform.exitCode, 0, reason: platform.stderr.toString());
          expect(
            platform.stdout.toString().trim(),
            p.dirname(p.dirname(p.dirname(paths[target]!))),
          );
        }
      }
      for (final rejected in [
        'macosx',
        'iphoneosbogus',
        'iphonesimulatorbogus',
        'iphonesimulator26.4',
        '',
      ]) {
        expect(
          (await probe(['--sdk=$rejected', '--show-sdk-path'])).exitCode,
          1,
        );
        expect(
          (await probe(['--sdk=$rejected', '--find', 'clang'])).exitCode,
          1,
        );
      }
      File('$executable.sdk').writeAsStringSync(paths[IosTarget.simulator]!);
      expect(
        (await probe(['--show-sdk-version'])).stdout.toString().trim(),
        '26.5',
      );
      expect(
        (await probe(['--show-sdk-path'])).stdout.toString().trim(),
        paths[IosTarget.simulator],
      );
      expect((await probe(['--sdk=iphoneos', '--show-sdk-path'])).exitCode, 1);
      File('$executable.sdk').deleteSync();
      Directory(paths[IosTarget.simulator]!).deleteSync(recursive: true);
      expect(
        (await probe(['--sdk=iphonesimulator', '--show-sdk-path'])).exitCode,
        1,
      );
      expect(
        (await probe(['--sdk=iphonesimulator', '--show-sdk-version'])).exitCode,
        1,
      );
      expect(
        (await probe(['--sdk=iphonesimulator', '--find', 'clang'])).exitCode,
        1,
      );
    },
  );

  test(
    'unversioned sidecar uses SDKSettings version without changing sdkRoot',
    () {
      final directory = Directory.systemTemp.createTempSync(
        'xcross-xcrun-settings-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final executable = p.join(directory.path, 'xcrun.exe');
      for (final target in IosTarget.values) {
        final sdk = p.join(directory.path, '${target.platformName}.sdk');
        Directory(sdk).createSync();
        File(
          p.join(sdk, 'SDKSettings.json'),
        ).writeAsStringSync('{"Version":"26.5"}');
        File('$executable.sdk').writeAsStringSync('$sdk\n');
        for (final name in [target.sdkName, '${target.sdkName}26.5']) {
          expect(
            xcrun.xcrunShimResponse([
              '--sdk=$name',
              '--show-sdk-version',
            ], executable: executable),
            '26.5',
          );
          expect(
            xcrun.xcrunShimResponse([
              '--sdk=$name',
              '--show-sdk-path',
            ], executable: executable),
            sdk,
          );
        }
        expect(
          () => xcrun.xcrunShimResponse([
            '--sdk=${target.sdkName}26.4',
            '--show-sdk-version',
          ], executable: executable),
          throwsFormatException,
        );
        File(
          p.join(sdk, 'SDKSettings.json'),
        ).writeAsStringSync('{"Version":"bogus"}');
        expect(
          () => xcrun.xcrunShimResponse([
            '--show-sdk-version',
          ], executable: executable),
          throwsFormatException,
        );
        File(p.join(sdk, 'SDKSettings.json')).deleteSync();
        expect(
          () => xcrun.xcrunShimResponse([
            '--show-sdk-version',
          ], executable: executable),
          throwsFormatException,
        );
      }
    },
  );

  test('rejects macOS SDK sidecars before compiler lookup', () async {
    final directory = Directory.systemTemp.createTempSync(
      'xcross-xcrun-macos-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final executable = p.join(directory.path, 'xcrun.exe');
    File('$executable.sdk').writeAsStringSync('/sdk/MacOSX26.5.sdk');
    File(p.join(directory.path, 'clang.exe')).writeAsStringSync('');
    expect(
      () =>
          xcrun.xcrunShimResponse(['--show-sdk-path'], executable: executable),
      throwsFormatException,
    );
    expect(
      () => xcrun.findShimTool(['--find', 'clang'], executable: executable),
      throwsFormatException,
    );
    expect(
      await xcrun.runXcrun(
        ['clang'],
        sdk: DarwinSdk('/unused'),
        executable: executable,
        findOnPath: (_) async =>
            throw StateError('must not resolve a mismatched compiler'),
      ),
      1,
    );
  });

  test('macOS entry point rejects the cross-host shim', () async {
    final rootShim = File(
      p.join(Directory.current.path, 'packages', 'xcross', 'bin', 'xcrun.dart'),
    );
    final shim = rootShim.existsSync()
        ? rootShim
        : File(p.join(Directory.current.path, 'bin', 'xcrun.dart'));
    final packageConfig =
        Platform.packageConfig ??
        p.join(Directory.current.path, '.dart_tool', 'package_config.json');
    final result = await Process.run(Platform.resolvedExecutable, [
      '--packages=$packageConfig',
      shim.path,
      '--version',
    ]);
    expect(result.exitCode, 1);
    expect(result.stderr, contains('only intended for Windows and Linux'));
  }, skip: !Platform.isMacOS);

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
    File('$executable.sdk').writeAsStringSync('/sdk/iPhoneOS.sdk');
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
    expect(await xcrun.runXcrun(const [], sdk: DarwinSdk('/unused')), 1);
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
      for (final probe in [
        '--show-sdk-path',
        '--show-sdk-version',
        '--show-sdk-platform-path',
      ]) {
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
      '--show-sdk-version',
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
      '--show-sdk-version',
      '--show-sdk-platform-path',
      '--sdk=macosx',
      '--find',
    ]);
  });
}
