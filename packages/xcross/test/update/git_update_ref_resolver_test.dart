import 'dart:io';

import 'package:test/test.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/update/git_update_ref_resolver.dart';

void main() {
  group('GitUpdateRefResolver.resolve', () {
    test(
      'classifies an exact tag before a branch with the same shorthand',
      () async {
        final runner = _FakeGitRunner([
          _GitCall(
            arguments: const [
              'ls-remote',
              'https://github.com/arxdeus/xcross.git',
              'refs/tags/release',
              'refs/tags/release^{}',
            ],
            result: _result(
              stdout:
                  '1111111111111111111111111111111111111111\trefs/tags/release\n',
            ),
          ),
        ]);
        final resolver = GitUpdateRefResolver(run: runner.run);

        final resolved = await resolver.resolve('release');

        expect(resolved.kind, GitUpdateRefKind.tag);
        expect(resolved.displayName, 'release');
        expect(resolved.fetchRef, 'refs/tags/release');
        expect(resolved.commitSha, '1111111111111111111111111111111111111111');
        expect(runner.calls, hasLength(1));
      },
    );

    test('classifies a full tag ref and uses the peeled commit sha', () async {
      final runner = _FakeGitRunner([
        _GitCall(
          arguments: const [
            'ls-remote',
            'https://github.com/arxdeus/xcross.git',
            'refs/tags/v1.2.3',
            'refs/tags/v1.2.3^{}',
          ],
          result: _result(
            stdout:
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\trefs/tags/v1.2.3\n'
                'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\trefs/tags/v1.2.3^{}\n',
          ),
        ),
      ]);
      final resolver = GitUpdateRefResolver(run: runner.run);

      final resolved = await resolver.resolve('refs/tags/v1.2.3');

      expect(resolved.kind, GitUpdateRefKind.tag);
      expect(resolved.displayName, 'v1.2.3');
      expect(resolved.fetchRef, 'refs/tags/v1.2.3');
      expect(resolved.commitSha, 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb');
    });

    test('classifies a branch after the exact tag probe misses', () async {
      final runner = _FakeGitRunner([
        _GitCall(
          arguments: const [
            'ls-remote',
            'https://github.com/arxdeus/xcross.git',
            'refs/tags/main',
            'refs/tags/main^{}',
          ],
          result: _result(exitCode: 2, stderr: 'no tag'),
        ),
        _GitCall(
          arguments: const [
            'ls-remote',
            'https://github.com/arxdeus/xcross.git',
            'refs/heads/main',
          ],
          result: _result(
            stdout:
                '2222222222222222222222222222222222222222\trefs/heads/main\n',
          ),
        ),
      ]);
      final resolver = GitUpdateRefResolver(run: runner.run);

      final resolved = await resolver.resolve('main');

      expect(resolved.kind, GitUpdateRefKind.branch);
      expect(resolved.displayName, 'main');
      expect(resolved.fetchRef, 'refs/heads/main');
      expect(resolved.commitSha, '2222222222222222222222222222222222222222');
      expect(
        runner.calls,
        equals([
          [
            'ls-remote',
            'https://github.com/arxdeus/xcross.git',
            'refs/tags/main',
            'refs/tags/main^{}',
          ],
          [
            'ls-remote',
            'https://github.com/arxdeus/xcross.git',
            'refs/heads/main',
          ],
        ]),
      );
    });

    test('classifies a full branch ref', () async {
      final runner = _FakeGitRunner([
        _GitCall(
          arguments: const [
            'ls-remote',
            'https://github.com/arxdeus/xcross.git',
            'refs/heads/stable',
          ],
          result: _result(
            stdout:
                '3333333333333333333333333333333333333333\trefs/heads/stable\n',
          ),
        ),
      ]);
      final resolver = GitUpdateRefResolver(run: runner.run);

      final resolved = await resolver.resolve('refs/heads/stable');

      expect(resolved.kind, GitUpdateRefKind.branch);
      expect(resolved.displayName, 'stable');
      expect(resolved.fetchRef, 'refs/heads/stable');
      expect(resolved.commitSha, '3333333333333333333333333333333333333333');
    });

    test(
      'resolves a commit sha through a temporary fetch and rev-parse',
      () async {
        const sha = '4444444444444444444444444444444444444444';
        final runner = _FakeGitRunner([
          _GitCall(
            arguments: const [
              'ls-remote',
              'https://github.com/arxdeus/xcross.git',
              'refs/tags/$sha',
              'refs/tags/$sha^{}',
            ],
            result: _result(exitCode: 2),
          ),
          _GitCall(
            arguments: const [
              'ls-remote',
              'https://github.com/arxdeus/xcross.git',
              'refs/heads/$sha',
            ],
            result: _result(exitCode: 2),
          ),
          _GitCall(
            arguments: const ['init'],
            workingDirectory: '/tmp/fake-xcross-update-1',
            result: _result(),
          ),
          _GitCall(
            arguments: const [
              'fetch',
              '--depth=1',
              'https://github.com/arxdeus/xcross.git',
              sha,
            ],
            workingDirectory: '/tmp/fake-xcross-update-1',
            result: _result(),
          ),
          _GitCall(
            arguments: const ['rev-parse', 'FETCH_HEAD'],
            workingDirectory: '/tmp/fake-xcross-update-1',
            result: _result(stdout: '$sha\n'),
          ),
        ]);
        final tempDirs = _FakeTempDirectories([
          Directory('/tmp/fake-xcross-update-1'),
        ]);
        final deleted = <String>[];
        final resolver = GitUpdateRefResolver(
          run: runner.run,
          createTempDirectory: tempDirs.create,
          deleteDirectory: (directory) async => deleted.add(directory.path),
        );

        final resolved = await resolver.resolve(sha);

        expect(resolved.kind, GitUpdateRefKind.commit);
        expect(resolved.displayName, sha);
        expect(resolved.fetchRef, sha);
        expect(resolved.commitSha, sha);
        expect(tempDirs.prefixes, ['xcross-update-ref-']);
        expect(deleted, ['/tmp/fake-xcross-update-1']);
      },
    );

    test('treats any other fetchable ref as a commit kind', () async {
      final runner = _FakeGitRunner([
        _GitCall(
          arguments: const [
            'ls-remote',
            'https://github.com/arxdeus/xcross.git',
            'refs/tags/pull/12/head',
            'refs/tags/pull/12/head^{}',
          ],
          result: _result(exitCode: 2),
        ),
        _GitCall(
          arguments: const [
            'ls-remote',
            'https://github.com/arxdeus/xcross.git',
            'refs/heads/pull/12/head',
          ],
          result: _result(exitCode: 2),
        ),
        _GitCall(
          arguments: const ['init'],
          workingDirectory: '/tmp/fake-xcross-update-2',
          result: _result(),
        ),
        _GitCall(
          arguments: const [
            'fetch',
            '--depth=1',
            'https://github.com/arxdeus/xcross.git',
            'pull/12/head',
          ],
          workingDirectory: '/tmp/fake-xcross-update-2',
          result: _result(),
        ),
        _GitCall(
          arguments: const ['rev-parse', 'FETCH_HEAD'],
          workingDirectory: '/tmp/fake-xcross-update-2',
          result: _result(stdout: '5555555555555555555555555555555555555555\n'),
        ),
      ]);
      final tempDirs = _FakeTempDirectories([
        Directory('/tmp/fake-xcross-update-2'),
      ]);
      final deleted = <String>[];
      final resolver = GitUpdateRefResolver(
        run: runner.run,
        createTempDirectory: tempDirs.create,
        deleteDirectory: (directory) async => deleted.add(directory.path),
      );

      final resolved = await resolver.resolve('pull/12/head');

      expect(resolved.kind, GitUpdateRefKind.commit);
      expect(resolved.displayName, 'pull/12/head');
      expect(resolved.fetchRef, 'pull/12/head');
      expect(resolved.commitSha, '5555555555555555555555555555555555555555');
      expect(deleted, ['/tmp/fake-xcross-update-2']);
    });

    test('deletes the temporary directory when fallback fetch fails', () async {
      final runner = _FakeGitRunner([
        _GitCall(
          arguments: const [
            'ls-remote',
            'https://github.com/arxdeus/xcross.git',
            'refs/tags/missing',
            'refs/tags/missing^{}',
          ],
          result: _result(exitCode: 2),
        ),
        _GitCall(
          arguments: const [
            'ls-remote',
            'https://github.com/arxdeus/xcross.git',
            'refs/heads/missing',
          ],
          result: _result(exitCode: 2),
        ),
        _GitCall(
          arguments: const ['init'],
          workingDirectory: '/tmp/fake-xcross-update-3',
          result: _result(),
        ),
        _GitCall(
          arguments: const [
            'fetch',
            '--depth=1',
            'https://github.com/arxdeus/xcross.git',
            'missing',
          ],
          workingDirectory: '/tmp/fake-xcross-update-3',
          result: _result(
            exitCode: 128,
            stderr: 'fatal: could not find remote ref missing',
          ),
        ),
      ]);
      final tempDirs = _FakeTempDirectories([
        Directory('/tmp/fake-xcross-update-3'),
      ]);
      final deleted = <String>[];
      final resolver = GitUpdateRefResolver(
        run: runner.run,
        createTempDirectory: tempDirs.create,
        deleteDirectory: (directory) async => deleted.add(directory.path),
      );

      await expectLater(
        () => resolver.resolve('missing'),
        throwsA(
          isA<XcrossError>().having(
            (e) => e.message,
            'message',
            contains('fatal: could not find remote ref missing'),
          ),
        ),
      );
      expect(deleted, ['/tmp/fake-xcross-update-3']);
    });
  });
}

ProcessResult _result({
  int exitCode = 0,
  String stdout = '',
  String stderr = '',
}) => ProcessResult(1, exitCode, stdout, stderr);

final class _FakeGitRunner {
  _FakeGitRunner(this._calls);

  final List<_GitCall> _calls;
  final calls = <List<String>>[];

  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    expect(executable, 'git');
    final index = calls.length;
    if (index >= _calls.length) {
      fail('unexpected git call: $arguments @ $workingDirectory');
    }
    final call = _calls[index];
    calls.add(arguments);
    expect(arguments, call.arguments);
    expect(workingDirectory, call.workingDirectory);
    return call.result;
  }
}

final class _GitCall {
  const _GitCall({
    required this.arguments,
    required this.result,
    this.workingDirectory,
  });

  final List<String> arguments;
  final ProcessResult result;
  final String? workingDirectory;
}

final class _FakeTempDirectories {
  _FakeTempDirectories(this._directories);

  final List<Directory> _directories;
  final prefixes = <String>[];

  Future<Directory> create(String prefix) async {
    prefixes.add(prefix);
    if (_directories.isEmpty) fail('unexpected temp directory request');
    return _directories.removeAt(0);
  }
}
