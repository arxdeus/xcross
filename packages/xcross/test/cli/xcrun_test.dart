import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/composition/xcrun_sdk.dart';
import 'package:xcross/src/host/macos/xcrun/native_xcrun.dart';
import 'package:xcross/src/host/windows/xcrun/windows_executable.dart';
import 'package:xcross/src/shared/xcrun/cross_xcrun.dart' as xcrun;
import 'package:xcross/src/shared/xcrun/xcrun_operation.dart';

import '../host_operations_fixtures.dart';
import '../setup/host_ops_residual_fixtures.dart';

void main() {
  test('lazy output uses supplied sink without runtime loading', () async {
    final unused = fixtureSink();
    final selected = fixtureSink();
    final errors = fixtureSink();
    final loader = FixtureUnusedLoader();
    final operation = xcrun.CrossXcrunOperation(
      loader,
      host: LinuxHost(),
      executable: '/fixture/missing-xcrun',
      output: selected,
      errors: errors,
    );
    expect(await operation.run(['--version']), 0);
    expect(selected.buffer.toString(), 'xcrun version 72.\n');
    expect(unused.buffer.isEmpty, isTrue);
    expect(errors.buffer.isEmpty, isTrue);
    expect(loader.calls, 0);
  });

  test(
    'cross version and trusted sidecar probes never load configuration',
    () async {
      final directory = Directory.systemTemp.createTempSync('lazy-xcrun-');
      final executable = p.join(directory.path, 'xcrun');
      File(
        '$executable.sdk',
      ).writeAsStringSync('/fixture/iPhoneSimulator26.0.sdk');
      final loader = FixtureUnusedLoader();
      final output = FixtureProbeOutput();
      try {
        await IOOverrides.runZoned(() async {
          final operation = xcrun.CrossXcrunOperation(
            loader,
            host: LinuxHost(),
            executable: executable,
            output: output,
            errors: fixtureSink(),
          );
          expect(await operation.run(['--version']), 0);
          expect(
            await operation.run([
              '--sdk',
              'iphonesimulator',
              '--show-sdk-path',
            ]),
            0,
          );
        }, stdout: () => output);
        expect(
          output.buffer.toString(),
          contains('/fixture/iPhoneSimulator26.0.sdk'),
        );
        expect(loader.calls, 0);
      } finally {
        directory.deleteSync(recursive: true);
      }
    },
  );

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
          xcrun.CrossXcrunProbe(
            LinuxHost(),
          ).response([...selection, '--show-sdk-path'], executable: executable),
          sdk,
        );
        expect(
          xcrun.CrossXcrunProbe(LinuxHost()).response([
            ...selection,
            '--show-sdk-version',
          ], executable: executable),
          '26.5',
        );
        expect(
          xcrun.CrossXcrunProbe(LinuxHost()).response([
            ...selection,
            '--show-sdk-platform-path',
          ], executable: executable),
          platform,
        );
        expect(
          xcrun.CrossXcrunProbe(
            LinuxHost(),
          ).response([...selection, '--find', 'clang'], executable: executable),
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
          () => xcrun.CrossXcrunProbe(LinuxHost()).response([
            '--sdk=$rejected',
            '--show-sdk-path',
          ], executable: executable),
          throwsFormatException,
        );
        expect(
          () => xcrun.CrossXcrunProbe(LinuxHost()).response([
            '--sdk=$rejected',
            '--show-sdk-version',
          ], executable: executable),
          throwsFormatException,
        );
        expect(
          () => xcrun.CrossXcrunProbe(LinuxHost()).findTool([
            '--sdk=$rejected',
            '--find',
            'clang',
          ], executable: executable),
          throwsFormatException,
        );
      }
      expect(
        () => xcrun.CrossXcrunProbe(
          LinuxHost(),
        ).response(['--sdk'], executable: executable),
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
        xcrun.CrossXcrunProbe(LinuxHost()).response([
          '--sdk=iphonesimulator',
          '--show-sdk-path',
        ], executable: executable),
        sdk,
      );
      expect(
        xcrun.CrossXcrunProbe(
          LinuxHost(),
        ).response(['--show-sdk-version'], executable: executable),
        '26.5',
      );
      expect(
        xcrun.CrossXcrunProbe(
          LinuxHost(),
        ).response(['--show-sdk-platform-path'], executable: executable),
        r'C:\SDK\iPhoneSimulator.platform',
      );
      expect(
        () => xcrun.CrossXcrunProbe(LinuxHost()).response([
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
          await _runXcrun(
            [...selection, 'clang', '--sdk=iphoneos'],
            sdk: const DarwinSdk('/unused'),
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
          await _runXcrun(
            ['--sdk=$rejected', '--find', 'clang'],
            sdk: const DarwinSdk('/unused'),
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
      final paths = <String, String>{};
      for (final target in const <IosBuildPlatformInterface>[
        IPhoneBuildPlatform(),
        SimulatorBuildPlatform(),
      ]) {
        paths[target.sdkName] = p.join(
          bundle,
          'Developer',
          'Platforms',
          '${target.platformName}.platform',
          'Developer',
          'SDKs',
          '${target.platformName}26.5.sdk',
        );
        Directory(paths[target.sdkName]!).createSync(recursive: true);
      }
      final executable = p.join(directory.path, 'xcrun.exe');
      Future<ProcessResult> probe(List<String> arguments) async {
        final output = FixtureProbeOutput();
        final errors = FixtureProbeOutput();
        final code = await IOOverrides.runZoned(
          () => _runXcrun(
            arguments,
            sdk: DarwinSdk(bundle),
            executable: executable,
          ),
          stdout: () => output,
          stderr: () => errors,
        );
        return ProcessResult(
          0,
          code,
          output.buffer.toString(),
          errors.buffer.toString(),
        );
      }

      for (final target in const <IosBuildPlatformInterface>[
        IPhoneBuildPlatform(),
        SimulatorBuildPlatform(),
      ]) {
        for (final selection in <List<String>>[
          if (target.sdkName == 'iphoneos') [],
          ['--sdk', target.sdkName],
          ['--sdk=${target.sdkName}26.5'],
        ]) {
          final path = await probe([...selection, '--show-sdk-path']);
          expect(path.exitCode, 0, reason: path.stderr.toString());
          expect(path.stdout.toString().trim(), paths[target.sdkName]);
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
            p.dirname(p.dirname(p.dirname(paths[target.sdkName]!))),
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
      File('$executable.sdk').writeAsStringSync(paths['iphonesimulator']!);
      expect(
        (await probe(['--show-sdk-version'])).stdout.toString().trim(),
        '26.5',
      );
      expect(
        (await probe(['--show-sdk-path'])).stdout.toString().trim(),
        paths['iphonesimulator'],
      );
      expect((await probe(['--sdk=iphoneos', '--show-sdk-path'])).exitCode, 1);
      File('$executable.sdk').deleteSync();
      Directory(paths['iphonesimulator']!).deleteSync(recursive: true);
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
      for (final target in const <IosBuildPlatformInterface>[
        IPhoneBuildPlatform(),
        SimulatorBuildPlatform(),
      ]) {
        final sdk = p.join(directory.path, '${target.platformName}.sdk');
        Directory(sdk).createSync();
        File(
          p.join(sdk, 'SDKSettings.json'),
        ).writeAsStringSync('{"Version":"26.5"}');
        File('$executable.sdk').writeAsStringSync('$sdk\n');
        for (final name in [target.sdkName, '${target.sdkName}26.5']) {
          expect(
            xcrun.CrossXcrunProbe(LinuxHost()).response([
              '--sdk=$name',
              '--show-sdk-version',
            ], executable: executable),
            '26.5',
          );
          expect(
            xcrun.CrossXcrunProbe(LinuxHost()).response([
              '--sdk=$name',
              '--show-sdk-path',
            ], executable: executable),
            sdk,
          );
        }
        expect(
          () => xcrun.CrossXcrunProbe(LinuxHost()).response([
            '--sdk=${target.sdkName}26.4',
            '--show-sdk-version',
          ], executable: executable),
          throwsFormatException,
        );
        File(
          p.join(sdk, 'SDKSettings.json'),
        ).writeAsStringSync('{"Version":"bogus"}');
        expect(
          () => xcrun.CrossXcrunProbe(
            LinuxHost(),
          ).response(['--show-sdk-version'], executable: executable),
          throwsFormatException,
        );
        File(p.join(sdk, 'SDKSettings.json')).deleteSync();
        expect(
          () => xcrun.CrossXcrunProbe(
            LinuxHost(),
          ).response(['--show-sdk-version'], executable: executable),
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
      () => xcrun.CrossXcrunProbe(
        LinuxHost(),
      ).response(['--show-sdk-path'], executable: executable),
      throwsFormatException,
    );
    expect(
      () => xcrun.CrossXcrunProbe(
        LinuxHost(),
      ).findTool(['--find', 'clang'], executable: executable),
      throwsFormatException,
    );
    expect(
      await _runXcrun(
        ['clang'],
        sdk: const DarwinSdk('/unused'),
        executable: executable,
        findOnPath: (_) async =>
            throw StateError('must not resolve a mismatched compiler'),
      ),
      1,
    );
  });

  test(
    'native bootstrap preserves environment and never reads configuration',
    () async {
      final processes = FixtureNativeProcesses();
      final host = MacOSHost(
        environment: {
          'DEVELOPER_DIR': '/chosen developer',
          'XCROSS_CONFIG': '/invalid-config',
          'PATH': '/shadow',
        },
        processes: processes,
      );
      final arguments = ['--sdk', 'iphonesimulator', 'clang', '', '--version'];
      expect(await NativeMacXcrun(host).run(arguments), 37);
      expect(processes.executable, '/usr/bin/xcrun');
      expect(identical(processes.arguments, arguments), isTrue);
      expect(processes.environment, host.environment.values);
      expect(processes.includeParentEnvironment, isFalse);
      expect(processes.mode, ProcessStartMode.inheritStdio);
    },
  );

  test(
    'native delegation preserves arguments, inherited stdio and exit code',
    () async {
      final arguments = ['--sdk', 'iphonesimulator', 'clang', '--version', ''];
      final child = FixtureNativeChild();
      expect(
        await NativeMacXcrun(
          MacOSHost(),
          start: (tool, forwarded, {required mode}) async {
            expect(tool, '/usr/bin/xcrun');
            expect(identical(forwarded, arguments), isTrue);
            expect(mode, ProcessStartMode.inheritStdio);
            return child;
          },
        ).run(arguments),
        37,
      );
    },
  );

  test('native delegation propagates process startup failure', () async {
    const error = ProcessException(
      '/usr/bin/xcrun',
      ['--version'],
      'denied',
      13,
    );
    await expectLater(
      NativeMacXcrun(
        MacOSHost(),
        start: (_, _, {required mode}) async => throw error,
      ).run(['--version']),
      throwsA(same(error)),
    );
  });

  test('falls back without a sidecar or a supported sibling tool', () {
    final directory = Directory.systemTemp.createTempSync('xcross-xcrun-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final executable = p.join(directory.path, 'xcrun.exe');
    expect(
      xcrun.CrossXcrunProbe(
        LinuxHost(),
      ).response(const ['--show-sdk-path'], executable: executable),
      isNull,
    );
    File('$executable.sdk').writeAsStringSync('/sdk/iPhoneOS.sdk');
    File(p.join(directory.path, 'arbitrary.exe')).writeAsStringSync('');
    expect(
      xcrun.CrossXcrunProbe(
        LinuxHost(),
      ).response(const ['--find', 'arbitrary'], executable: executable),
      isNull,
    );
    expect(
      xcrun.CrossXcrunProbe(
        LinuxHost(),
      ).response(const ['--find', 'clang'], executable: executable),
      isNull,
    );
  });
  test('answers its own version without an SDK sidecar', () {
    final directory = Directory.systemTemp.createTempSync('xcross-xcrun-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final executable = p.join(directory.path, 'xcrun.exe');
    expect(
      xcrun.CrossXcrunProbe(
        LinuxHost(),
      ).response(const ['--version'], executable: executable),
      'xcrun version ${xcrun.xcrunCompatVersion}.',
    );
    expect(
      xcrun.CrossXcrunProbe(
        LinuxHost(),
      ).response(const ['-version'], executable: executable),
      'xcrun version ${xcrun.xcrunCompatVersion}.',
    );
  });
  test('rejects an invocation without a tool', () async {
    expect(await _runXcrun(const [], sdk: const DarwinSdk('/unused')), 1);
  });

  test('answers the --version probe without an SDK', () async {
    expect(await _runXcrun(const ['--version']), 0);
  });

  test('normalizes PATHEXT uppercase .EXE for native_toolchain_c', () {
    expect(
      normalizeWindowsExecutableExtension(r'C:\Temp\xcross-tools\clang.EXE'),
      r'C:\Temp\xcross-tools\clang.exe',
    );
    expect(
      normalizeWindowsExecutableExtension(r'C:\Temp\xcross-tools\ar.EXE'),
      r'C:\Temp\xcross-tools\ar.exe',
    );
  });

  test('returns the exact streamed child exit code', () async {
    final host = residualProcessHost(
      LinuxHost(),
      (_, _, _) async => ResidualChild(code: 37),
    );
    final runner = residualRunner(host);
    final command = xcrun.XcrunSdkCommand(
      runner: runner,
      output: fixtureSink(),
      errors: fixtureSink(),
      repository: DarwinSdkRepository(
        host,
        log: runner.log,
        installBundle: '/fixture/missing-sdk',
      ),
      toolchain: DarwinToolchainResolver(
        runner,
        LinuxDarwinToolchainLocations(host),
      ),
      executable: '/fixture/xcrun',
      normalizeExecutable: (path) => path,
      target: const IPhoneBuildPlatform(),
    );
    expect(await command.runResolvedTool('/ignored', const []), 37);
  });

  test('prefers build shims on PATH for known Apple tools', () async {
    const sdk = DarwinSdk('/unused');
    for (final tool in const ['clang', 'otool']) {
      final shim = '/build/shims/$tool';
      expect(
        await _runXcrun(
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
        xcrun.CrossXcrunProbe(
          LinuxHost(),
        ).response(const ['--show-sdk-path'], executable: executable.path),
        sdk,
      );
      final clang = File('${directory.path}${Platform.pathSeparator}clang.exe')
        ..writeAsStringSync('');

      expect(
        xcrun.CrossXcrunProbe(
          LinuxHost(),
        ).response(const ['--find', 'clang'], executable: executable.path),
        clang.path,
      );
      expect(
        xcrun.CrossXcrunProbe(
          LinuxHost(),
        ).response(const ['--version'], executable: executable.path),
        'xcrun version ${xcrun.xcrunCompatVersion}.',
      );
      expect(
        xcrun.CrossXcrunProbe(LinuxHost()).response(const [
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
          xcrun.CrossXcrunProbe(LinuxHost()).response([
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
        xcrun.CrossXcrunProbe(LinuxHost()).response(const [
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
          () => xcrun.CrossXcrunProbe(
            LinuxHost(),
          ).response(arguments, executable: executable.path),
          throwsFormatException,
        );
      }
      expect(
        xcrun.CrossXcrunProbe(LinuxHost()).response(const [
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
      await _runXcrun(const [
        '--sdk=macosx',
        '--find',
        'clang',
      ], sdk: const DarwinSdk('/unused')),
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
        await _runXcrun(
          ['clang', probe],
          sdk: const DarwinSdk('/unused'),
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

Future<int> _runXcrun(
  List<String> arguments, {
  DarwinSdk? sdk,
  String executable = '/fixture/xcrun',
  Future<String?> Function(String)? findOnPath,
  Future<int> Function(String, List<String>)? runTool,
}) {
  final host = residualProcessHost(
    LinuxHost(),
    (tool, arguments, _) async => ResidualChild(
      code: runTool == null ? 0 : await runTool(tool, arguments),
    ),
  );
  final runner = residualRunner(
    host,
    lookup: findOnPath == null ? null : (name, _) => findOnPath(name),
  );
  return xcrun.XcrunSdkCommand(
    runner: runner,
    output: stdout,
    errors: stderr,
    repository: DarwinSdkRepository(
      host,
      log: runner.log,
      installBundle: '/fixture/missing-sdk',
    ),
    toolchain: DarwinToolchainResolver(
      runner,
      LinuxDarwinToolchainLocations(host),
    ),
    normalizeExecutable: (path) => path,
    target: _fixtureTarget(arguments),
    executable: executable,
  ).run(arguments, sdk: sdk);
}

final class FixtureProbeOutput implements Stdout {
  final buffer = StringBuffer();
  @override
  void writeln([Object? value = '']) => buffer.writeln(value);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class FixtureNativeProcesses implements HostProcessInterface {
  String? executable;
  List<String>? arguments;
  Map<String, String>? environment;
  bool? includeParentEnvironment;
  ProcessStartMode? mode;
  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    this.executable = executable;
    this.arguments = arguments;
    this.environment = environment;
    this.includeParentEnvironment = includeParentEnvironment;
    this.mode = mode;
    return FixtureNativeChild();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class FixtureNativeChild implements Process {
  @override
  Future<int> get exitCode async => 37;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

String _requestedSdkForFixture(List<String> arguments) {
  for (var index = 0; index < arguments.length; index++) {
    if (arguments[index] == '--sdk' && index + 1 < arguments.length) {
      return arguments[index + 1];
    }
    if (arguments[index].startsWith('--sdk=')) {
      return arguments[index].substring(6);
    }
    if (!arguments[index].startsWith('-')) break;
  }
  return 'iphoneos';
}

IosBuildPlatformInterface _fixtureTarget(List<String> arguments) {
  try {
    return parseXcrunSdkName(_requestedSdkForFixture(arguments));
  } on FormatException {
    return const IPhoneBuildPlatform();
  }
}

final class FixtureUnusedLoader implements XcrunRuntimeLoader {
  int calls = 0;
  @override
  Future<XcrunServices> loadXcrun({required String sdkName}) {
    calls++;
    return Future.error(StateError('configuration must not load'));
  }
}
