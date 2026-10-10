import 'dart:async';
import 'dart:io';

import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/update/git_ref_source_bundle_builder.dart';
import 'package:xcross/src/shared/update/git_update_ref_resolver.dart';

import '../host_operations_fixtures.dart';

Future<List<String>> _captureAsync(Future<void> Function() body) async {
  final lines = <String>[];
  await runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      print: (_, _, _, line) => lines.add(line),
    ),
  );
  return lines;
}

void main() {
  group('GitRefSourceBundleBuilder.build', () {
    test(
      testOn: '!windows',
      'deletes only stale source-update temp directories',
      () async {
        final scratch = _createScratchDirectory();
        final systemTemp = Directory(p.join(scratch.path, 'tmp'))
          ..createSync(recursive: true);
        final stale = Directory(
          p.join(systemTemp.path, 'xcross-update-source-abandoned'),
        )..createSync();
        final active = Directory(
          p.join(systemTemp.path, 'xcross-update-source-active'),
        )..createSync();
        final unrelated = Directory(
          p.join(systemTemp.path, 'xcross-self-update'),
        )..createSync();
        final staging = Directory(p.join(scratch.path, 'staging'));
        final repo = Directory(p.join(staging.path, 'xcross'));
        final bundle = Directory(
          p.join(
            repo.path,
            'packages',
            'xcross',
            'build',
            'cli',
            'linux_x64',
            'bundle',
          ),
        );
        var staleWasDeletedBeforeClone = false;
        final runner = FixtureFakeProcessRunner(
          onRun: (call) async {
            if (call.arguments.first == 'clone') {
              staleWasDeletedBeforeClone = !stale.existsSync();
            }
            if (call.arguments.contains('tool/build_xcross.dart')) {
              _createBundle(bundle);
            }
            return _result();
          },
        );
        final builder = _createTestBuilder(
          run: runner.run,
          createTempDirectory: (_) =>
              Future.value(staging..createSync(recursive: true)),
          deleteDirectory: _deleteDirectorySync,
          systemTempDirectory: systemTemp,
          tempDirectoryModifiedAt: (directory) => directory.path == stale.path
              ? DateTime.now().subtract(const Duration(hours: 1))
              : DateTime.now(),
        );

        await builder.build<void>(
          ref: const GitUpdateRef(
            kind: GitUpdateRefKind.branch,
            displayName: 'main',
            fetchRef: 'refs/heads/main',
            commitSha: '1234567890abcdef1234567890abcdef12345678',
          ),
          onBundle: (_, _) async {},
        );

        expect(staleWasDeletedBeforeClone, isTrue);
        expect(active.existsSync(), isTrue);
        expect(unrelated.existsSync(), isTrue);
      },
    );

    test(
      testOn: '!windows',
      'reuses one Dart launcher for source update commands',
      () async {
        final scratch = _createScratchDirectory();
        final staging = Directory(p.join(scratch.path, 'staging'));
        final repo = Directory(p.join(staging.path, 'xcross'));
        final bundle = Directory(
          p.join(
            repo.path,
            'packages',
            'xcross',
            'build',
            'cli',
            'linux_x64',
            'bundle',
          ),
        );
        final dartInvocations = <String>[];
        final runner = FixtureFakeProcessRunner(
          onRun: (call) async {
            if (call.arguments.first == 'pub' ||
                call.arguments.contains('tool/build_xcross.dart')) {
              dartInvocations.add(call.executable);
            }
            if (call.arguments.contains('tool/build_xcross.dart')) {
              _createBundle(bundle);
            }
            return _result();
          },
        );
        final builder = _createTestBuilder(
          run: runner.run,
          createTempDirectory: (_) =>
              Future.value(staging..createSync(recursive: true)),
          deleteDirectory: _deleteDirectorySync,
        );

        await builder.build<void>(
          ref: const GitUpdateRef(
            kind: GitUpdateRefKind.branch,
            displayName: 'main',
            fetchRef: 'refs/heads/main',
            commitSha: '1234567890abcdef1234567890abcdef12345678',
          ),
          onBundle: (_, _) async {},
        );

        expect(dartInvocations, List.filled(2, _fakeDartExecutable));
      },
    );

    test('fails on a missing Dart before any source phase runs', () async {
      final runner = FixtureFakeProcessRunner(onRun: (_) async => _result());
      var createdTempDirectory = false;
      final builder = _createTestBuilder(
        run: runner.run,
        createTempDirectory: (_) {
          createdTempDirectory = true;
          throw StateError('temp directory must not be created');
        },
        resolveDartExecutable: () async =>
            throw XcrossError('failed to locate required executable "dart"'),
      );

      await expectLater(
        builder.build<void>(
          ref: const GitUpdateRef(
            kind: GitUpdateRefKind.branch,
            displayName: 'main',
            fetchRef: 'refs/heads/main',
            commitSha: '1234567890abcdef1234567890abcdef12345678',
          ),
          onBundle: (_, _) async {},
        ),
        throwsA(isA<XcrossError>()),
      );

      expect(runner.calls, isEmpty);
      expect(createdTempDirectory, isFalse);
    });

    test(
      testOn: '!windows',
      'reports numbered source phases in order',
      () async {
        final scratch = _createScratchDirectory();
        final staging = Directory(p.join(scratch.path, 'staging'));
        final repo = Directory(p.join(staging.path, 'xcross'));
        final bundle = Directory(
          p.join(
            repo.path,
            'packages',
            'xcross',
            'build',
            'cli',
            'linux_x64',
            'bundle',
          ),
        );
        final runner = FixtureFakeProcessRunner(
          onRun: (call) async {
            if (call.arguments.contains('tool/build_xcross.dart')) {
              _createBundle(bundle);
            }
            return _result();
          },
        );
        final builder = _createTestBuilder(
          run: runner.run,
          createTempDirectory: (_) =>
              Future.value(staging..createSync(recursive: true)),
          deleteDirectory: _deleteDirectorySync,
        );

        final output = await _captureAsync(() async {
          await builder.build<void>(
            ref: const GitUpdateRef(
              kind: GitUpdateRefKind.branch,
              displayName: 'main',
              fetchRef: 'refs/heads/main',
              commitSha: '1234567890abcdef1234567890abcdef12345678',
            ),
            onBundle: (_, _) async {},
          );
        });

        expect(
          output.where((line) => line.contains('Source [')),
          containsAllInOrder([
            contains('[1/7] Clone repository'),
            contains('[2/7] Fetch commit'),
            contains('[3/7] Check out commit'),
            contains('[4/7] Resolve dependencies'),
            contains('[5/7] Build xcross main'),
          ]),
        );
      },
    );

    test(
      testOn: '!windows',

      'builds a branch ref and exposes the bundle only inside the callback',
      () async {
        final scratch = _createScratchDirectory();
        final staging = Directory(p.join(scratch.path, 'staging'));
        final repo = Directory(p.join(staging.path, 'xcross'));
        final bundle = Directory(
          p.join(
            repo.path,
            'packages',
            'xcross',
            'build',
            'cli',
            'linux_x64',
            'bundle',
          ),
        );
        final runner = FixtureFakeProcessRunner(
          onRun: (call) async {
            if (call.arguments.contains('tool/build_xcross.dart')) {
              _createBundle(bundle);
            }
            return _result();
          },
        );
        final deleted = <String>[];
        final builder = _createTestBuilder(
          run: runner.run,
          createTempDirectory: (_) =>
              Future.value(staging..createSync(recursive: true)),
          deleteDirectory: (directory) async {
            deleted.add(directory.path);
            if (directory.existsSync()) {
              directory.deleteSync(recursive: true);
            }
          },
        );

        Directory? seenBundle;
        var callbackSawExistingBundle = false;
        await builder.build<void>(
          ref: const GitUpdateRef(
            kind: GitUpdateRefKind.branch,
            displayName: 'main',
            fetchRef: 'refs/heads/main',
            commitSha: '1234567890abcdef1234567890abcdef12345678',
          ),
          onBundle: (bundleDirectory, _) async {
            seenBundle = bundleDirectory;
            callbackSawExistingBundle = bundleDirectory.existsSync();
            expect(p.basename(bundleDirectory.path), 'bundle');
            expect(
              Directory(p.join(bundleDirectory.path, 'bin')).existsSync(),
              isTrue,
            );
            expect(
              Directory(p.join(bundleDirectory.path, 'lib')).existsSync(),
              isTrue,
            );
          },
        );

        expect(
          runner.calls,
          equals([
            FixtureProcessCall('git', [
              'clone',
              'https://github.com/arxdeus/xcross.git',
              repo.path,
            ]),
            FixtureProcessCall('git', const [
              'fetch',
              '--depth',
              '1',
              'origin',
              '1234567890abcdef1234567890abcdef12345678',
            ], workingDirectory: repo.path),
            FixtureProcessCall('git', const [
              'checkout',
              '--detach',
              '1234567890abcdef1234567890abcdef12345678',
            ], workingDirectory: repo.path),
            FixtureProcessCall(_fakeDartExecutable, const [
              'pub',
              'get',
            ], workingDirectory: repo.path),
            FixtureProcessCall(_fakeDartExecutable, const [
              'run',
              '-DXCROSS_VERSION=main',
              '-DXCROSS_RELEASED=false',
              'tool/build_xcross.dart',
            ], workingDirectory: p.join(repo.path, 'packages', 'xcross')),
          ]),
        );
        expect(callbackSawExistingBundle, isTrue);
        expect(seenBundle!.existsSync(), isFalse);
        expect(deleted, [staging.path]);
      },
    );

    test(
      testOn: '!windows',
      'encodes the ref display name into XCROSS_VERSION',
      () async {
        final scratch = _createScratchDirectory();
        final staging = Directory(p.join(scratch.path, 'staging'));
        final repo = Directory(p.join(staging.path, 'xcross'));
        final bundle = Directory(
          p.join(
            repo.path,
            'packages',
            'xcross',
            'build',
            'cli',
            'linux_x64',
            'bundle',
          ),
        );
        final runner = FixtureFakeProcessRunner(
          onRun: (call) async {
            if (call.arguments.contains('tool/build_xcross.dart')) {
              _createBundle(bundle);
            }
            return _result();
          },
        );
        final builder = _createTestBuilder(
          run: runner.run,
          createTempDirectory: (_) =>
              Future.value(staging..createSync(recursive: true)),
          deleteDirectory: _deleteDirectorySync,
        );

        await builder.build<void>(
          ref: const GitUpdateRef(
            kind: GitUpdateRefKind.branch,
            displayName: 'feature/a,b=c',
            fetchRef: 'refs/heads/feature/a,b=c',
            commitSha: '1234567890abcdef1234567890abcdef12345678',
          ),
          onBundle: (_, _) async {},
        );

        expect(
          runner.calls.last,
          FixtureProcessCall(_fakeDartExecutable, const [
            'run',
            '-DXCROSS_VERSION=feature%2Fa%2Cb%3Dc',
            '-DXCROSS_RELEASED=false',
            'tool/build_xcross.dart',
          ], workingDirectory: p.join(repo.path, 'packages', 'xcross')),
        );
      },
    );

    test(
      testOn: '!windows',
      'cleanup failure does not replace the callback result',
      () async {
        final scratch = _createScratchDirectory();
        final staging = Directory(p.join(scratch.path, 'staging'));
        final repo = Directory(p.join(staging.path, 'xcross'));
        final bundle = Directory(
          p.join(
            repo.path,
            'packages',
            'xcross',
            'build',
            'cli',
            'linux_x64',
            'bundle',
          ),
        );
        final builder = _createTestBuilder(
          run: FixtureFakeProcessRunner(
            onRun: (call) async {
              if (call.arguments.contains('tool/build_xcross.dart')) {
                _createBundle(bundle);
              }
              return _result();
            },
          ).run,
          createTempDirectory: (_) async =>
              staging..createSync(recursive: true),
          deleteDirectory: (_) async => throw StateError('cleanup failed'),
        );

        final result = await builder.build<String>(
          ref: const GitUpdateRef(
            kind: GitUpdateRefKind.branch,
            displayName: 'main',
            fetchRef: 'refs/heads/main',
            commitSha: '1234567890abcdef1234567890abcdef12345678',
          ),
          onBundle: (_, _) async => 'installed',
        );

        expect(result, 'installed');
      },
    );

    test(
      testOn: '!windows',

      'fetches and checks out the exact commit sha even when fetchRef differs',
      () async {
        final scratch = _createScratchDirectory();
        final staging = Directory(p.join(scratch.path, 'staging'));
        final repo = Directory(p.join(staging.path, 'xcross'));
        final bundle = Directory(
          p.join(
            repo.path,
            'packages',
            'xcross',
            'build',
            'cli',
            'linux_x64',
            'bundle',
          ),
        );
        final runner = FixtureFakeProcessRunner(
          onRun: (call) async {
            if (call.arguments.contains('tool/build_xcross.dart')) {
              _createBundle(bundle);
            }
            return _result();
          },
        );
        final builder = _createTestBuilder(
          run: runner.run,
          createTempDirectory: (_) =>
              Future.value(staging..createSync(recursive: true)),
          deleteDirectory: _deleteDirectorySync,
        );

        await builder.build<void>(
          ref: const GitUpdateRef(
            kind: GitUpdateRefKind.commit,
            displayName: 'feature-head',
            fetchRef: 'pull/42/head',
            commitSha: 'abcdefabcdefabcdefabcdefabcdefabcdefabcd',
          ),
          onBundle: (_, _) async {},
        );

        expect(
          runner.calls[1],
          FixtureProcessCall('git', const [
            'fetch',
            '--depth',
            '1',
            'origin',
            'abcdefabcdefabcdefabcdefabcdefabcdefabcd',
          ], workingDirectory: repo.path),
        );
        expect(
          runner.calls[2],
          FixtureProcessCall('git', const [
            'checkout',
            '--detach',
            'abcdefabcdefabcdefabcdefabcdefabcdefabcd',
          ], workingDirectory: repo.path),
        );
      },
    );

    test('deletes the temp directory when the build command fails', () async {
      final scratch = _createScratchDirectory();
      final staging = Directory(p.join(scratch.path, 'staging'));
      final repo = Directory(p.join(staging.path, 'xcross'));
      final deleted = <String>[];
      final builder = _createTestBuilder(
        run: FixtureFakeProcessRunner(
          onRun: (call) async {
            if (call.executable == 'git' && call.arguments.first == 'clone') {
              repo.createSync(recursive: true);
            }
            if (call.executable == _fakeDartExecutable &&
                call.arguments.contains('tool/build_xcross.dart')) {
              return _result(exitCode: 78, stderr: 'compile failed');
            }
            return _result();
          },
        ).run,
        createTempDirectory: (_) =>
            Future.value(staging..createSync(recursive: true)),
        deleteDirectory: (directory) async {
          deleted.add(directory.path);
          directory.deleteSync(recursive: true);
        },
      );

      await expectLater(
        () => builder.build<void>(
          ref: const GitUpdateRef(
            kind: GitUpdateRefKind.branch,
            displayName: 'main',
            fetchRef: 'refs/heads/main',
            commitSha: '1234567890abcdef1234567890abcdef12345678',
          ),
          onBundle: (_, _) async {},
        ),
        throwsA(
          isA<XcrossError>().having(
            (e) => e.message,
            'message',
            contains('compile failed'),
          ),
        ),
      );
      expect(deleted, [staging.path]);
    });

    test('cleanup failure does not replace the original build error', () async {
      final scratch = _createScratchDirectory();
      final staging = Directory(p.join(scratch.path, 'staging'));
      final repo = Directory(p.join(staging.path, 'xcross'));
      final builder = _createTestBuilder(
        run: FixtureFakeProcessRunner(
          onRun: (call) async {
            if (call.executable == 'git' && call.arguments.first == 'clone') {
              repo.createSync(recursive: true);
            }
            if (call.executable == _fakeDartExecutable &&
                call.arguments.contains('tool/build_xcross.dart')) {
              return _result(exitCode: 78, stderr: 'original build failed');
            }
            return _result();
          },
        ).run,
        createTempDirectory: (_) async => staging..createSync(recursive: true),
        deleteDirectory: (_) async => throw StateError('cleanup failed'),
      );

      await expectLater(
        () => builder.build<void>(
          ref: const GitUpdateRef(
            kind: GitUpdateRefKind.branch,
            displayName: 'main',
            fetchRef: 'refs/heads/main',
            commitSha: '1234567890abcdef1234567890abcdef12345678',
          ),
          onBundle: (_, _) async {},
        ),
        throwsA(
          isA<XcrossError>().having(
            (error) => error.message,
            'message',
            contains('original build failed'),
          ),
        ),
      );
    });

    test(
      testOn: '!windows',
      'deletes the temp directory when the callback fails',
      () async {
        final scratch = _createScratchDirectory();
        final staging = Directory(p.join(scratch.path, 'staging'));
        final repo = Directory(p.join(staging.path, 'xcross'));
        final bundle = Directory(
          p.join(
            repo.path,
            'packages',
            'xcross',
            'build',
            'cli',
            'linux_x64',
            'bundle',
          ),
        );
        final deleted = <String>[];
        final builder = _createTestBuilder(
          run: FixtureFakeProcessRunner(
            onRun: (call) async {
              if (call.executable == 'git' && call.arguments.first == 'clone') {
                repo.createSync(recursive: true);
              }
              if (call.executable == _fakeDartExecutable &&
                  call.arguments.contains('tool/build_xcross.dart')) {
                _createBundle(bundle);
              }
              return _result();
            },
          ).run,
          createTempDirectory: (_) =>
              Future.value(staging..createSync(recursive: true)),
          deleteDirectory: (directory) async {
            deleted.add(directory.path);
            directory.deleteSync(recursive: true);
          },
        );

        await expectLater(
          () => builder.build<void>(
            ref: const GitUpdateRef(
              kind: GitUpdateRefKind.branch,
              displayName: 'main',
              fetchRef: 'refs/heads/main',
              commitSha: '1234567890abcdef1234567890abcdef12345678',
            ),
            onBundle: (_, _) async => throw StateError('callback exploded'),
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'callback exploded',
            ),
          ),
        );
        expect(deleted, [staging.path]);
      },
    );

    test(
      testOn: '!windows',

      'cleanup failure does not replace the original callback error',
      () async {
        final scratch = _createScratchDirectory();
        final staging = Directory(p.join(scratch.path, 'staging'));
        final repo = Directory(p.join(staging.path, 'xcross'));
        final bundle = Directory(
          p.join(
            repo.path,
            'packages',
            'xcross',
            'build',
            'cli',
            'linux_x64',
            'bundle',
          ),
        );
        final builder = _createTestBuilder(
          run: FixtureFakeProcessRunner(
            onRun: (call) async {
              if (call.executable == 'git' && call.arguments.first == 'clone') {
                repo.createSync(recursive: true);
              }
              if (call.executable == _fakeDartExecutable &&
                  call.arguments.contains('tool/build_xcross.dart')) {
                _createBundle(bundle);
              }
              return _result();
            },
          ).run,
          createTempDirectory: (_) async =>
              staging..createSync(recursive: true),
          deleteDirectory: (_) async => throw StateError('cleanup failed'),
        );

        await expectLater(
          () => builder.build<void>(
            ref: const GitUpdateRef(
              kind: GitUpdateRefKind.branch,
              displayName: 'main',
              fetchRef: 'refs/heads/main',
              commitSha: '1234567890abcdef1234567890abcdef12345678',
            ),
            onBundle: (_, _) async => throw StateError('callback exploded'),
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'callback exploded',
            ),
          ),
        );
      },
    );

    test('rejects tag refs defensively', () async {
      final builder = _createTestBuilder(
        run: FixtureFakeProcessRunner(onRun: (_) async => _result()).run,
      );

      await expectLater(
        () => builder.build<void>(
          ref: const GitUpdateRef(
            kind: GitUpdateRefKind.tag,
            displayName: 'v1.2.3',
            fetchRef: 'refs/tags/v1.2.3',
            commitSha: '1234567890abcdef1234567890abcdef12345678',
          ),
          onBundle: (_, _) async {},
        ),
        throwsA(
          isA<XcrossError>().having(
            (e) => e.message,
            'message',
            contains('non-tag git update refs'),
          ),
        ),
      );
    });

    test(testOn: '!windows', 'throws when no built bundle exists', () async {
      final scratch = _createScratchDirectory();
      final staging = Directory(p.join(scratch.path, 'staging'));
      final repo = Directory(p.join(staging.path, 'xcross'));
      final builder = _createTestBuilder(
        run: FixtureFakeProcessRunner(
          onRun: (call) async {
            if (call.executable == 'git' && call.arguments.first == 'clone') {
              repo.createSync(recursive: true);
            }
            return _result();
          },
        ).run,
        createTempDirectory: (_) =>
            Future.value(staging..createSync(recursive: true)),
        deleteDirectory: _deleteDirectorySync,
      );

      await expectLater(
        () => builder.build<void>(
          ref: const GitUpdateRef(
            kind: GitUpdateRefKind.branch,
            displayName: 'main',
            fetchRef: 'refs/heads/main',
            commitSha: '1234567890abcdef1234567890abcdef12345678',
          ),
          onBundle: (_, _) async {},
        ),
        throwsA(
          isA<XcrossError>().having(
            (e) => e.message,
            'message',
            contains('expected built update bundle'),
          ),
        ),
      );
    });

    test(
      testOn: '!windows',

      'selects the current native bundle despite stale other-ABI output',
      () async {
        final scratch = _createScratchDirectory();
        final staging = Directory(p.join(scratch.path, 'staging'));
        final repo = Directory(p.join(staging.path, 'xcross'));
        final builder = _createTestBuilder(
          run: FixtureFakeProcessRunner(
            onRun: (call) async {
              if (call.executable == 'git' && call.arguments.first == 'clone') {
                repo.createSync(recursive: true);
              }
              if (call.executable == _fakeDartExecutable &&
                  call.arguments.contains('tool/build_xcross.dart')) {
                for (final target in ['linux_x64', 'macos_arm64']) {
                  Directory(
                    p.join(
                      repo.path,
                      'packages',
                      'xcross',
                      'build',
                      'cli',
                      target,
                      'bundle',
                      'bin',
                    ),
                  ).createSync(recursive: true);
                  Directory(
                    p.join(
                      repo.path,
                      'packages',
                      'xcross',
                      'build',
                      'cli',
                      target,
                      'bundle',
                      'lib',
                    ),
                  ).createSync(recursive: true);
                }
              }
              return _result();
            },
          ).run,
          createTempDirectory: (_) =>
              Future.value(staging..createSync(recursive: true)),
          deleteDirectory: _deleteDirectorySync,
        );

        await builder.build<void>(
          ref: const GitUpdateRef(
            kind: GitUpdateRefKind.branch,
            displayName: 'main',
            fetchRef: 'refs/heads/main',
            commitSha: '1234567890abcdef1234567890abcdef12345678',
          ),
          onBundle: (bundle, _) async {
            expect(bundle.path, endsWith(p.join('linux_x64', 'bundle')));
          },
        );
      },
    );
  });
}

GitRefSourceBundleBuilder _createTestBuilder({
  RunGitProcess? run,
  CreateTempDirectory? createTempDirectory,
  DeleteDirectory? deleteDirectory,
  Directory? systemTempDirectory,
  TempDirectoryModifiedAt? tempDirectoryModifiedAt,
  DartExecutableLocator? resolveDartExecutable,
}) => GitRefSourceBundleBuilder(
  runner: fixtureRunner(LinuxHost(architecture: 'x64'), log: fixtureLog()),
  acceptDartLauncher: (path) => path.endsWith('/dart'),
  run: run,
  createTempDirectory: createTempDirectory,
  deleteDirectory: deleteDirectory,
  systemTempDirectory: systemTempDirectory,
  tempDirectoryModifiedAt: tempDirectoryModifiedAt,
  resolveDartExecutable:
      resolveDartExecutable ?? () async => _fakeDartExecutable,
);

Directory _createScratchDirectory() {
  final scratch = Directory.systemTemp.createTempSync('git-ref-bundle-test-');
  addTearDown(() {
    if (scratch.existsSync()) {
      scratch.deleteSync(recursive: true);
    }
  });
  return scratch;
}

void _createBundle(Directory bundle) {
  Directory(p.join(bundle.path, 'bin')).createSync(recursive: true);
  Directory(p.join(bundle.path, 'lib')).createSync(recursive: true);
}

Future<void> _deleteDirectorySync(Directory directory) async {
  directory.deleteSync(recursive: true);
}

const _fakeDartExecutable = '/fake/sdk/bin/dart';

ProcessResult _result({
  int exitCode = 0,
  String stdout = '',
  String stderr = '',
}) => ProcessResult(1, exitCode, stdout, stderr);

@internal
final class FixtureFakeProcessRunner {
  FixtureFakeProcessRunner({required this.onRun});

  final Future<ProcessResult> Function(FixtureProcessCall call) onRun;
  final calls = <FixtureProcessCall>[];

  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) {
    final call = FixtureProcessCall(
      executable,
      List<String>.unmodifiable(arguments),
      workingDirectory: workingDirectory,
    );
    calls.add(call);
    return onRun(call);
  }
}

@internal
@immutable
final class FixtureProcessCall {
  const FixtureProcessCall(
    this.executable,
    this.arguments, {
    this.workingDirectory,
  });

  final String executable;
  final List<String> arguments;
  final String? workingDirectory;

  @override
  bool operator ==(Object other) =>
      other is FixtureProcessCall &&
      other.executable == executable &&
      _listEquals(other.arguments, arguments) &&
      other.workingDirectory == workingDirectory;

  @override
  int get hashCode =>
      Object.hash(executable, Object.hashAll(arguments), workingDirectory);

  @override
  String toString() => '$executable ${arguments.join(' ')} @ $workingDirectory';
}

bool _listEquals(List<Object?> a, List<Object?> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}
