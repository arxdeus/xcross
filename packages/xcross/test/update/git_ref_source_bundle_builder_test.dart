import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/update/git_ref_source_bundle_builder.dart';
import 'package:xcross/src/update/git_update_ref_resolver.dart';

void main() {
  group('GitRefSourceBundleBuilder.build', () {
    test('builds a branch ref and exposes the bundle only inside the callback', () async {
      final scratch = await Directory.systemTemp.createTemp('git-ref-bundle-test-');
      addTearDown(() async {
        if (await scratch.exists()) {
          await scratch.delete(recursive: true);
        }
      });
      final staging = Directory(p.join(scratch.path, 'staging'));
      final repo = Directory(p.join(staging.path, 'xcross'));
      final bundle = Directory(
        p.join(repo.path, 'packages', 'xcross', 'build', 'cli', 'linux-x64', 'bundle'),
      );
      final runner = _FakeProcessRunner(onRun: (call) async {
        if (call.arguments.first == 'build') {
          await Directory(p.join(bundle.path, 'bin')).create(recursive: true);
          await Directory(p.join(bundle.path, 'lib')).create(recursive: true);
        }
        return _result();
      });
      final deleted = <String>[];
      final builder = GitRefSourceBundleBuilder(
        run: runner.run,
        createTempDirectory: (_) async {
          await staging.create(recursive: true);
          return staging;
        },
        deleteDirectory: (directory) async {
          deleted.add(directory.path);
          if (await directory.exists()) {
            await directory.delete(recursive: true);
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
        onBundle: (bundleDirectory) async {
          seenBundle = bundleDirectory;
          callbackSawExistingBundle = await bundleDirectory.exists();
          expect(p.basename(bundleDirectory.path), 'bundle');
          expect(await Directory(p.join(bundleDirectory.path, 'bin')).exists(), isTrue);
          expect(await Directory(p.join(bundleDirectory.path, 'lib')).exists(), isTrue);
        },
      );

      expect(
        runner.calls,
        equals([
          _ProcessCall('git', [
            'clone',
            'https://github.com/arxdeus/xcross.git',
            repo.path,
          ]),
          _ProcessCall(
            'git',
            const [
              'fetch',
              '--depth',
              '1',
              'origin',
              'refs/heads/main',
            ],
            workingDirectory: repo.path,
          ),
          _ProcessCall(
            'git',
            const ['checkout', '--detach', '1234567890abcdef1234567890abcdef12345678'],
            workingDirectory: repo.path,
          ),
          _ProcessCall(
            'dart',
            const ['pub', 'get'],
            workingDirectory: repo.path,
          ),
          _ProcessCall(
            'dart',
            const ['build', 'cli', '-t', 'bin/xcross.dart'],
            workingDirectory: p.join(repo.path, 'packages', 'xcross'),
          ),
        ]),
      );
      expect(callbackSawExistingBundle, isTrue);
      expect(await seenBundle!.exists(), isFalse);
      expect(deleted, [staging.path]);
    });

    test('builds a commit ref using its fetchRef and detached commit sha', () async {
      final scratch = await Directory.systemTemp.createTemp('git-ref-bundle-test-');
      addTearDown(() async {
        if (await scratch.exists()) {
          await scratch.delete(recursive: true);
        }
      });
      final staging = Directory(p.join(scratch.path, 'staging'));
      final repo = Directory(p.join(staging.path, 'xcross'));
      final bundle = Directory(
        p.join(repo.path, 'packages', 'xcross', 'build', 'cli', 'macos-arm64', 'bundle'),
      );
      final runner = _FakeProcessRunner(onRun: (call) async {
        if (call.arguments.first == 'build') {
          await Directory(p.join(bundle.path, 'bin')).create(recursive: true);
          await Directory(p.join(bundle.path, 'lib')).create(recursive: true);
        }
        return _result();
      });
      final builder = GitRefSourceBundleBuilder(
        run: runner.run,
        createTempDirectory: (_) async {
          await staging.create(recursive: true);
          return staging;
        },
        deleteDirectory: (directory) async => directory.delete(recursive: true),
      );

      await builder.build<void>(
        ref: const GitUpdateRef(
          kind: GitUpdateRefKind.commit,
          displayName: 'feature-head',
          fetchRef: 'pull/42/head',
          commitSha: 'abcdefabcdefabcdefabcdefabcdefabcdefabcd',
        ),
        onBundle: (_) async {},
      );

      expect(
        runner.calls[1],
        _ProcessCall(
          'git',
          const ['fetch', '--depth', '1', 'origin', 'pull/42/head'],
          workingDirectory: repo.path,
        ),
      );
      expect(
        runner.calls[2],
        _ProcessCall(
          'git',
          const ['checkout', '--detach', 'abcdefabcdefabcdefabcdefabcdefabcdefabcd'],
          workingDirectory: repo.path,
        ),
      );
    });

    test('deletes the temp directory when the build command fails', () async {
      final scratch = await Directory.systemTemp.createTemp('git-ref-bundle-test-');
      addTearDown(() async {
        if (await scratch.exists()) {
          await scratch.delete(recursive: true);
        }
      });
      final staging = Directory(p.join(scratch.path, 'staging'));
      final repo = Directory(p.join(staging.path, 'xcross'));
      final deleted = <String>[];
      final builder = GitRefSourceBundleBuilder(
        run: _FakeProcessRunner(onRun: (call) async {
          if (call.executable == 'git' && call.arguments.first == 'clone') {
            await repo.create(recursive: true);
          }
          if (call.executable == 'dart' && call.arguments.first == 'build') {
            return _result(exitCode: 78, stderr: 'compile failed');
          }
          return _result();
        }).run,
        createTempDirectory: (_) async {
          await staging.create(recursive: true);
          return staging;
        },
        deleteDirectory: (directory) async {
          deleted.add(directory.path);
          await directory.delete(recursive: true);
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
          onBundle: (_) async {},
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

    test('deletes the temp directory when the callback fails', () async {
      final scratch = await Directory.systemTemp.createTemp('git-ref-bundle-test-');
      addTearDown(() async {
        if (await scratch.exists()) {
          await scratch.delete(recursive: true);
        }
      });
      final staging = Directory(p.join(scratch.path, 'staging'));
      final repo = Directory(p.join(staging.path, 'xcross'));
      final bundle = Directory(
        p.join(repo.path, 'packages', 'xcross', 'build', 'cli', 'linux-x64', 'bundle'),
      );
      final deleted = <String>[];
      final builder = GitRefSourceBundleBuilder(
        run: _FakeProcessRunner(onRun: (call) async {
          if (call.executable == 'git' && call.arguments.first == 'clone') {
            await repo.create(recursive: true);
          }
          if (call.executable == 'dart' && call.arguments.first == 'build') {
            await Directory(p.join(bundle.path, 'bin')).create(recursive: true);
            await Directory(p.join(bundle.path, 'lib')).create(recursive: true);
          }
          return _result();
        }).run,
        createTempDirectory: (_) async {
          await staging.create(recursive: true);
          return staging;
        },
        deleteDirectory: (directory) async {
          deleted.add(directory.path);
          await directory.delete(recursive: true);
        },
      );

      try {
        await builder.build<void>(
          ref: const GitUpdateRef(
            kind: GitUpdateRefKind.branch,
            displayName: 'main',
            fetchRef: 'refs/heads/main',
            commitSha: '1234567890abcdef1234567890abcdef12345678',
          ),
          onBundle: (_) async => throw StateError('callback exploded'),
        );
        fail('expected callback failure');
      } on StateError catch (error) {
        expect(error.message, 'callback exploded');
      }
      expect(deleted, [staging.path]);
    });

    test('rejects tag refs defensively', () async {
      final builder = GitRefSourceBundleBuilder(
        run: _FakeProcessRunner(onRun: (_) async => _result()).run,
      );

      await expectLater(
        () => builder.build<void>(
          ref: const GitUpdateRef(
            kind: GitUpdateRefKind.tag,
            displayName: 'v1.2.3',
            fetchRef: 'refs/tags/v1.2.3',
            commitSha: '1234567890abcdef1234567890abcdef12345678',
          ),
          onBundle: (_) async {},
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

    test('throws when no built bundle exists', () async {
      final scratch = await Directory.systemTemp.createTemp('git-ref-bundle-test-');
      addTearDown(() async {
        if (await scratch.exists()) {
          await scratch.delete(recursive: true);
        }
      });
      final staging = Directory(p.join(scratch.path, 'staging'));
      final repo = Directory(p.join(staging.path, 'xcross'));
      final builder = GitRefSourceBundleBuilder(
        run: _FakeProcessRunner(onRun: (call) async {
          if (call.executable == 'git' && call.arguments.first == 'clone') {
            await repo.create(recursive: true);
          }
          return _result();
        }).run,
        createTempDirectory: (_) async {
          await staging.create(recursive: true);
          return staging;
        },
        deleteDirectory: (directory) async => directory.delete(recursive: true),
      );

      await expectLater(
        () => builder.build<void>(
          ref: const GitUpdateRef(
            kind: GitUpdateRefKind.branch,
            displayName: 'main',
            fetchRef: 'refs/heads/main',
            commitSha: '1234567890abcdef1234567890abcdef12345678',
          ),
          onBundle: (_) async {},
        ),
        throwsA(
          isA<XcrossError>().having(
            (e) => e.message,
            'message',
            contains('expected exactly one built update bundle'),
          ),
        ),
      );
    });

    test('throws when multiple built bundles exist', () async {
      final scratch = await Directory.systemTemp.createTemp('git-ref-bundle-test-');
      addTearDown(() async {
        if (await scratch.exists()) {
          await scratch.delete(recursive: true);
        }
      });
      final staging = Directory(p.join(scratch.path, 'staging'));
      final repo = Directory(p.join(staging.path, 'xcross'));
      final builder = GitRefSourceBundleBuilder(
        run: _FakeProcessRunner(onRun: (call) async {
          if (call.executable == 'git' && call.arguments.first == 'clone') {
            await repo.create(recursive: true);
          }
          if (call.executable == 'dart' && call.arguments.first == 'build') {
            for (final target in ['linux-x64', 'macos-arm64']) {
              await Directory(
                p.join(repo.path, 'packages', 'xcross', 'build', 'cli', target, 'bundle', 'bin'),
              ).create(recursive: true);
              await Directory(
                p.join(repo.path, 'packages', 'xcross', 'build', 'cli', target, 'bundle', 'lib'),
              ).create(recursive: true);
            }
          }
          return _result();
        }).run,
        createTempDirectory: (_) async {
          await staging.create(recursive: true);
          return staging;
        },
        deleteDirectory: (directory) async => directory.delete(recursive: true),
      );

      await expectLater(
        () => builder.build<void>(
          ref: const GitUpdateRef(
            kind: GitUpdateRefKind.branch,
            displayName: 'main',
            fetchRef: 'refs/heads/main',
            commitSha: '1234567890abcdef1234567890abcdef12345678',
          ),
          onBundle: (_) async {},
        ),
        throwsA(
          isA<XcrossError>().having(
            (e) => e.message,
            'message',
            contains('expected exactly one built update bundle'),
          ),
        ),
      );
    });
  });
}

ProcessResult _result({int exitCode = 0, String stdout = '', String stderr = ''}) =>
    ProcessResult(1, exitCode, stdout, stderr);

final class _FakeProcessRunner {
  _FakeProcessRunner({required this.onRun});

  final Future<ProcessResult> Function(_ProcessCall call) onRun;
  final calls = <_ProcessCall>[];

  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    final call = _ProcessCall(
      executable,
      List<String>.unmodifiable(arguments),
      workingDirectory: workingDirectory,
    );
    calls.add(call);
    return onRun(call);
  }
}

final class _ProcessCall {
  const _ProcessCall(this.executable, this.arguments, {this.workingDirectory});

  final String executable;
  final List<String> arguments;
  final String? workingDirectory;

  @override
  bool operator ==(Object other) =>
      other is _ProcessCall &&
      other.executable == executable &&
      _listEquals(other.arguments, arguments) &&
      other.workingDirectory == workingDirectory;

  @override
  int get hashCode => Object.hash(executable, Object.hashAll(arguments), workingDirectory);

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
