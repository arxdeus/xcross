import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/update/git_ref_source_bundle_builder.dart';
import 'package:xcross/src/update/git_update_ref_resolver.dart';

Future<List<String>> _captureAsync(Future<void> Function() body) async {
  final lines = <String>[];
  await runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      print: (_, __, ___, line) => lines.add(line),
    ),
  );
  return lines;
}

void main() {
  group('GitRefSourceBundleBuilder.build', () {
    test('reports numbered source phases in order', () async {
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
          'linux-x64',
          'bundle',
        ),
      );
      final runner = _FakeProcessRunner(
        onRun: (call) async {
          if (call.arguments.contains('tool/build_xcross.dart')) {
            _createBundle(bundle);
          }
          return _result();
        },
      );
      final builder = GitRefSourceBundleBuilder(
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
          onBundle: (_, __) async {},
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
    });

    test(
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
            'linux-x64',
            'bundle',
          ),
        );
        final runner = _FakeProcessRunner(
          onRun: (call) async {
            if (call.arguments.contains('tool/build_xcross.dart')) {
              _createBundle(bundle);
            }
            return _result();
          },
        );
        final deleted = <String>[];
        final builder = GitRefSourceBundleBuilder(
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
            _ProcessCall('git', [
              'clone',
              'https://github.com/arxdeus/xcross.git',
              repo.path,
            ]),
            _ProcessCall('git', const [
              'fetch',
              '--depth',
              '1',
              'origin',
              '1234567890abcdef1234567890abcdef12345678',
            ], workingDirectory: repo.path),
            _ProcessCall('git', const [
              'checkout',
              '--detach',
              '1234567890abcdef1234567890abcdef12345678',
            ], workingDirectory: repo.path),
            _ProcessCall('dart', const [
              'pub',
              'get',
            ], workingDirectory: repo.path),
            _ProcessCall('dart', const [
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

    test('encodes the ref display name into XCROSS_VERSION', () async {
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
          'linux-x64',
          'bundle',
        ),
      );
      final runner = _FakeProcessRunner(
        onRun: (call) async {
          if (call.arguments.contains('tool/build_xcross.dart')) {
            _createBundle(bundle);
          }
          return _result();
        },
      );
      final builder = GitRefSourceBundleBuilder(
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
        onBundle: (_, __) async {},
      );

      expect(
        runner.calls.last,
        _ProcessCall('dart', const [
          'run',
          '-DXCROSS_VERSION=feature%2Fa%2Cb%3Dc',
          '-DXCROSS_RELEASED=false',
          'tool/build_xcross.dart',
        ], workingDirectory: p.join(repo.path, 'packages', 'xcross')),
      );
    });

    test('cleanup failure does not replace the callback result', () async {
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
          'linux-x64',
          'bundle',
        ),
      );
      final builder = GitRefSourceBundleBuilder(
        run: _FakeProcessRunner(
          onRun: (call) async {
            if (call.arguments.contains('tool/build_xcross.dart')) {
              _createBundle(bundle);
            }
            return _result();
          },
        ).run,
        createTempDirectory: (_) async => staging..createSync(recursive: true),
        deleteDirectory: (_) async => throw StateError('cleanup failed'),
      );

      final result = await builder.build<String>(
        ref: const GitUpdateRef(
          kind: GitUpdateRefKind.branch,
          displayName: 'main',
          fetchRef: 'refs/heads/main',
          commitSha: '1234567890abcdef1234567890abcdef12345678',
        ),
        onBundle: (_, __) async => 'installed',
      );

      expect(result, 'installed');
    });

    test(
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
            'macos-arm64',
            'bundle',
          ),
        );
        final runner = _FakeProcessRunner(
          onRun: (call) async {
            if (call.arguments.contains('tool/build_xcross.dart')) {
              _createBundle(bundle);
            }
            return _result();
          },
        );
        final builder = GitRefSourceBundleBuilder(
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
          onBundle: (_, __) async {},
        );

        expect(
          runner.calls[1],
          _ProcessCall('git', const [
            'fetch',
            '--depth',
            '1',
            'origin',
            'abcdefabcdefabcdefabcdefabcdefabcdefabcd',
          ], workingDirectory: repo.path),
        );
        expect(
          runner.calls[2],
          _ProcessCall('git', const [
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
      final builder = GitRefSourceBundleBuilder(
        run: _FakeProcessRunner(
          onRun: (call) async {
            if (call.executable == 'git' && call.arguments.first == 'clone') {
              repo.createSync(recursive: true);
            }
            if (call.executable == 'dart' &&
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
          onBundle: (_, __) async {},
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
      final builder = GitRefSourceBundleBuilder(
        run: _FakeProcessRunner(
          onRun: (call) async {
            if (call.executable == 'git' && call.arguments.first == 'clone') {
              repo.createSync(recursive: true);
            }
            if (call.executable == 'dart' &&
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
          onBundle: (_, __) async {},
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

    test('deletes the temp directory when the callback fails', () async {
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
          'linux-x64',
          'bundle',
        ),
      );
      final deleted = <String>[];
      final builder = GitRefSourceBundleBuilder(
        run: _FakeProcessRunner(
          onRun: (call) async {
            if (call.executable == 'git' && call.arguments.first == 'clone') {
              repo.createSync(recursive: true);
            }
            if (call.executable == 'dart' &&
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
          onBundle: (_, __) async => throw StateError('callback exploded'),
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
    });

    test(
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
            'linux-x64',
            'bundle',
          ),
        );
        final builder = GitRefSourceBundleBuilder(
          run: _FakeProcessRunner(
            onRun: (call) async {
              if (call.executable == 'git' && call.arguments.first == 'clone') {
                repo.createSync(recursive: true);
              }
              if (call.executable == 'dart' &&
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
            onBundle: (_, __) async => throw StateError('callback exploded'),
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
          onBundle: (_, __) async {},
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
      final scratch = _createScratchDirectory();
      final staging = Directory(p.join(scratch.path, 'staging'));
      final repo = Directory(p.join(staging.path, 'xcross'));
      final builder = GitRefSourceBundleBuilder(
        run: _FakeProcessRunner(
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
          onBundle: (_, __) async {},
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
      final scratch = _createScratchDirectory();
      final staging = Directory(p.join(scratch.path, 'staging'));
      final repo = Directory(p.join(staging.path, 'xcross'));
      final builder = GitRefSourceBundleBuilder(
        run: _FakeProcessRunner(
          onRun: (call) async {
            if (call.executable == 'git' && call.arguments.first == 'clone') {
              repo.createSync(recursive: true);
            }
            if (call.executable == 'dart' &&
                call.arguments.contains('tool/build_xcross.dart')) {
              for (final target in ['linux-x64', 'macos-arm64']) {
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

      await expectLater(
        () => builder.build<void>(
          ref: const GitUpdateRef(
            kind: GitUpdateRefKind.branch,
            displayName: 'main',
            fetchRef: 'refs/heads/main',
            commitSha: '1234567890abcdef1234567890abcdef12345678',
          ),
          onBundle: (_, __) async {},
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

ProcessResult _result({
  int exitCode = 0,
  String stdout = '',
  String stderr = '',
}) => ProcessResult(1, exitCode, stdout, stderr);

final class _FakeProcessRunner {
  _FakeProcessRunner({required this.onRun});

  final Future<ProcessResult> Function(_ProcessCall call) onRun;
  final calls = <_ProcessCall>[];

  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) {
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
