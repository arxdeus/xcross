import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:cli_kit/shared/process/process_models.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../tool/build_xcross.dart';
import '../host_operations_fixtures.dart';

void main() {
  late Directory sandbox;
  late String generatedPath;

  void seed({
    String pubspecVersion = '1.2.1',
    String generatedSource =
        "part of 'version.dart';\n\nconst String _xcrossBuildVersion = 'unreleased';\nconst bool _xcrossBuildReleased = false;\n",
  }) {
    File(
      p.join(sandbox.path, 'pubspec.yaml'),
    ).writeAsStringSync('name: xcross\nversion: $pubspecVersion\n');
    final lib = Directory(
      p.join(sandbox.path, 'lib', 'src', 'shared', 'runtime'),
    )..createSync(recursive: true);
    generatedPath = p.join(lib.path, 'version.g.dart');
    File(generatedPath).writeAsStringSync(generatedSource);
    final builtBin = Directory(
      p.join(sandbox.path, 'build', 'cli', 'linux_x64', 'bundle', 'bin'),
    )..createSync(recursive: true);
    File(
      p.join(builtBin.path, Platform.isWindows ? 'xcross.exe' : 'xcross'),
    ).writeAsStringSync('');
    final xcrunBin = Directory(
      p.join(sandbox.path, 'build', 'xcrun', 'bundle', 'bin'),
    )..createSync(recursive: true);
    File(
      p.join(xcrunBin.path, Platform.isWindows ? 'xcrun.exe' : 'xcrun'),
    ).writeAsStringSync('');
  }

  setUp(() => sandbox = Directory.systemTemp.createTempSync('xcross-build-'));
  tearDown(() => sandbox.deleteSync(recursive: true));

  test(
    'copies xcrun only beside the xcross bundle from this invocation',
    () async {
      seed();
      final staleBin = p.join(
        sandbox.path,
        'build',
        'cli',
        'stale_arm64',
        'bundle',
        'bin',
      );
      Directory(staleBin).createSync(recursive: true);
      File(p.join(staleBin, 'xcross')).writeAsStringSync('old xcross');
      final staleXcrun = File(p.join(staleBin, 'xcrun'))
        ..writeAsStringSync('stale sibling');
      final currentOutput = p.join(sandbox.path, 'build', 'cli', 'linux_x64');
      final currentBin = p.join(currentOutput, 'bundle', 'bin');
      final original = File(generatedPath).readAsStringSync();
      final result = await buildXcross(
        output: fixtureSink(),
        errors: fixtureSink(),
        runner: fixtureRunner(
          LinuxHost(architecture: 'x64'),
          log: fixtureLog(),
        ),
        dartExecutable: '/fixture/dart',
        packageRoot: sandbox,
        encodedVersion: 'fixture/current',
        released: false,
        runBuild: (_, arguments, {required workingDirectory}) async {
          final target = arguments[arguments.indexOf('-t') + 1];
          if (target == 'bin/xcross.dart') {
            final output = arguments.contains('-o')
                ? arguments[arguments.indexOf('-o') + 1]
                : currentOutput;
            final bin = Directory(p.join(output, 'bundle', 'bin'))
              ..createSync(recursive: true);
            File(
              p.join(bin.path, 'xcross'),
            ).writeAsStringSync('current xcross');
          } else {
            File(
              p.join(sandbox.path, 'build', 'xcrun', 'bundle', 'bin', 'xcrun'),
            ).writeAsStringSync('current xcrun');
          }
          return 0;
        },
      );
      expect(result, 0);
      expect(
        File(p.join(currentBin, 'xcrun')).readAsStringSync(),
        'current xcrun',
      );
      expect(staleXcrun.readAsStringSync(), 'stale sibling');
      expect(File(generatedPath).readAsStringSync(), original);
    },
  );

  test('embeds decoded ref identity only while the build runs', () async {
    seed();
    final original = File(generatedPath).readAsStringSync();
    String? generatedDuringBuild;

    final result = await buildXcross(
      output: fixtureSink(),
      errors: fixtureSink(),
      runner: fixtureRunner(LinuxHost(architecture: 'x64'), log: fixtureLog()),
      dartExecutable: '/fixture/dart',
      packageRoot: sandbox,
      encodedVersion: Uri.encodeComponent('feature/a,b=c'),
      released: false,
      runBuild: (executable, arguments, {required workingDirectory}) async {
        generatedDuringBuild = File(generatedPath).readAsStringSync();
        return 0;
      },
    );

    expect(result, 0);
    expect(generatedDuringBuild, contains('"feature/a,b=c"'));
    expect(generatedDuringBuild, contains('false'));
    expect(File(generatedPath).readAsStringSync(), original);
  });

  test(
    'second compiler failure restores identity without publishing sibling',
    () async {
      seed();
      final original = File(generatedPath).readAsBytesSync();
      var builds = 0;
      final code = await buildXcross(
        runner: fixtureRunner(
          LinuxHost(architecture: 'x64'),
          log: fixtureLog(),
        ),
        output: fixtureSink(),
        errors: fixtureSink(),
        dartExecutable: '/fixture/dart',
        packageRoot: sandbox,
        encodedVersion: 'fixture/failed',
        released: false,
        runBuild: (_, _, {required workingDirectory}) async =>
            ++builds == 2 ? 23 : 0,
      );
      expect(code, 23);
      expect(
        File(
          p.join(
            sandbox.path,
            'build',
            'cli',
            'linux_x64',
            'bundle',
            'bin',
            'xcrun',
          ),
        ).existsSync(),
        isFalse,
      );
      expect(File(generatedPath).readAsBytesSync(), original);
    },
  );

  test('sibling copy failure restores identity', () async {
    seed();
    final original = File(generatedPath).readAsBytesSync();
    File(
      p.join(sandbox.path, 'build', 'xcrun', 'bundle', 'bin', 'xcrun'),
    ).deleteSync();
    await expectLater(
      buildXcross(
        runner: fixtureRunner(
          LinuxHost(architecture: 'x64'),
          log: fixtureLog(),
        ),
        output: fixtureSink(),
        errors: fixtureSink(),
        dartExecutable: '/fixture/dart',
        packageRoot: sandbox,
        encodedVersion: 'fixture/copy-failed',
        released: false,
        runBuild: (_, _, {required workingDirectory}) async => 0,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(File(generatedPath).readAsBytesSync(), original);
  });

  test('build child output belongs only to supplied sinks', () async {
    seed();
    final original = File(generatedPath).readAsBytesSync();
    final output = fixtureSink();
    final errors = fixtureSink();
    final unused = fixtureSink();
    addTearDown(output.close);
    addTearDown(errors.close);
    addTearDown(unused.close);
    final runner = ProcessRunner(
      LinuxHost(architecture: 'x64', processes: FixtureBuildProcesses()),
      log: fixtureLog(),
      stdinStream: const Stream.empty(),
      stdoutSink: unused,
      stderrSink: unused,
    );
    final code = await buildXcross(
      runner: runner,
      output: output,
      errors: errors,
      dartExecutable: '/fixture/dart',
      packageRoot: sandbox,
      encodedVersion: 'fixture/output',
      released: false,
    );
    expect(code, 39);
    expect(output.buffer.toString(), 'fixture output');
    expect(errors.buffer.toString(), 'fixture error');
    expect(unused.buffer.isEmpty, isTrue);
    expect(File(generatedPath).readAsBytesSync(), original);
  });

  test('restores the generated identity after a throwing runner', () async {
    seed();
    final original = File(generatedPath).readAsStringSync();

    await expectLater(
      () => buildXcross(
        output: fixtureSink(),
        errors: fixtureSink(),
        runner: fixtureRunner(
          LinuxHost(architecture: 'x64'),
          log: fixtureLog(),
        ),
        dartExecutable: '/fixture/dart',
        packageRoot: sandbox,
        encodedVersion: Uri.encodeComponent('feature/throw'),
        released: false,
        runBuild: (executable, arguments, {required workingDirectory}) {
          throw StateError('boom');
        },
      ),
      throwsA(isA<StateError>()),
    );

    expect(File(generatedPath).readAsStringSync(), original);
  });

  test('rejects a released non-semver identity', () async {
    seed();
    final original = File(generatedPath).readAsStringSync();

    await expectLater(
      () => buildXcross(
        output: fixtureSink(),
        errors: fixtureSink(),
        runner: fixtureRunner(
          LinuxHost(architecture: 'x64'),
          log: fixtureLog(),
        ),
        dartExecutable: '/fixture/dart',
        packageRoot: sandbox,
        encodedVersion: Uri.encodeComponent('feature/not-a-release'),
        released: true,
        runBuild: (executable, arguments, {required workingDirectory}) async =>
            0,
      ),
      throwsArgumentError,
    );

    expect(File(generatedPath).readAsStringSync(), original);
  });

  test(
    'rejects a released version whose core disagrees with pubspec.yaml',
    () async {
      seed();
      final original = File(generatedPath).readAsStringSync();

      await expectLater(
        () => buildXcross(
          output: fixtureSink(),
          errors: fixtureSink(),
          runner: fixtureRunner(
            LinuxHost(architecture: 'x64'),
            log: fixtureLog(),
          ),
          dartExecutable: '/fixture/dart',
          packageRoot: sandbox,
          encodedVersion: Uri.encodeComponent('2.0.0+1'),
          released: true,
          runBuild:
              (executable, arguments, {required workingDirectory}) async => 0,
        ),
        throwsArgumentError,
      );

      expect(File(generatedPath).readAsStringSync(), original);
    },
  );

  test(
    'normalizes a released v-prefixed tag to the pubspec core identity',
    () async {
      seed();
      final original = File(generatedPath).readAsStringSync();
      String? generatedDuringBuild;

      final result = await buildXcross(
        output: fixtureSink(),
        errors: fixtureSink(),
        runner: fixtureRunner(
          LinuxHost(architecture: 'x64'),
          log: fixtureLog(),
        ),
        dartExecutable: '/fixture/dart',
        packageRoot: sandbox,
        encodedVersion: Uri.encodeComponent('v1.2.1'),
        released: true,
        runBuild: (executable, arguments, {required workingDirectory}) async {
          generatedDuringBuild = File(generatedPath).readAsStringSync();
          return 0;
        },
      );

      expect(result, 0);
      expect(generatedDuringBuild, contains('"1.2.1"'));
      expect(generatedDuringBuild, contains('true'));
      expect(File(generatedPath).readAsStringSync(), original);
    },
  );
}

@internal
final class FixtureBuildProcesses implements HostProcessInterface {
  @override
  ProcessExitDiagnostic describeExit(int exitCode) {
    if (exitCode < 0 || exitCode > 255) {
      throw StateError('Unexpected fixture exit: $exitCode');
    }
    return const ProcessExitDiagnostic(crashed: false, description: null);
  }

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) => Future.value(FixtureBuildChild());
  @override
  Future<void> killTree(
    Process process, {
    Map<String, String>? environment,
    Map<String, String> executableOverrides = const {},
  }) async {}
  @override
  Future<String?> findOnShellPath(
    String name, {
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
  }) async => null;
}

@internal
final class FixtureBuildChild implements Process {
  @override
  Future<int> get exitCode => Future.value(39);
  @override
  Stream<List<int>> get stdout => Stream.value(utf8.encode('fixture output'));
  @override
  Stream<List<int>> get stderr => Stream.value(utf8.encode('fixture error'));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
