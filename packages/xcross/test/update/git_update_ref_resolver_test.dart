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

    test('classifies a commit sha through the fallback probe', () async {
      const sha = '4444444444444444444444444444444444444444';
      final runner = _FakeGitRunner([
        _GitCall(
          arguments: const [
            'ls-remote',
            'https://github.com/arxdeus/xcross.git',
            'refs/tags/$sha',
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
          arguments: const [
            'ls-remote',
            'https://github.com/arxdeus/xcross.git',
            sha,
          ],
          result: _result(stdout: '$sha\t$sha\n'),
        ),
      ]);
      final resolver = GitUpdateRefResolver(run: runner.run);

      final resolved = await resolver.resolve(sha);

      expect(resolved.kind, GitUpdateRefKind.commit);
      expect(resolved.displayName, sha);
      expect(resolved.fetchRef, sha);
      expect(resolved.commitSha, sha);
    });

    test('treats any other fetchable ref as a commit kind', () async {
      final runner = _FakeGitRunner([
        _GitCall(
          arguments: const [
            'ls-remote',
            'https://github.com/arxdeus/xcross.git',
            'refs/tags/pull/12/head',
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
          arguments: const [
            'ls-remote',
            'https://github.com/arxdeus/xcross.git',
            'pull/12/head',
          ],
          result: _result(
            stdout:
                '5555555555555555555555555555555555555555\trefs/pull/12/head\n',
          ),
        ),
      ]);
      final resolver = GitUpdateRefResolver(run: runner.run);

      final resolved = await resolver.resolve('pull/12/head');

      expect(resolved.kind, GitUpdateRefKind.commit);
      expect(resolved.displayName, 'pull/12/head');
      expect(resolved.fetchRef, 'pull/12/head');
      expect(resolved.commitSha, '5555555555555555555555555555555555555555');
    });

    test('throws a useful error when the fallback fetch fails', () async {
      final runner = _FakeGitRunner([
        _GitCall(
          arguments: const [
            'ls-remote',
            'https://github.com/arxdeus/xcross.git',
            'refs/tags/missing',
          ],
          result: _result(exitCode: 2, stderr: 'no tag'),
        ),
        _GitCall(
          arguments: const [
            'ls-remote',
            'https://github.com/arxdeus/xcross.git',
            'refs/heads/missing',
          ],
          result: _result(exitCode: 2, stderr: 'no branch'),
        ),
        _GitCall(
          arguments: const [
            'ls-remote',
            'https://github.com/arxdeus/xcross.git',
            'missing',
          ],
          result: _result(
            exitCode: 128,
            stderr: 'fatal: could not find remote ref missing',
          ),
        ),
      ]);
      final resolver = GitUpdateRefResolver(run: runner.run);

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
    });
  });
}

ProcessResult _result({
  int exitCode = 0,
  String stdout = '',
  String stderr = '',
}) => ProcessResult(1, exitCode, stdout, stderr);

typedef _RunGit =
    Future<ProcessResult> Function(String executable, List<String> arguments);

final class _FakeGitRunner {
  _FakeGitRunner(this._calls);

  final List<_GitCall> _calls;
  final calls = <List<String>>[];

  Future<ProcessResult> run(String executable, List<String> arguments) async {
    expect(executable, 'git');
    final index = calls.length;
    if (index >= _calls.length) fail('unexpected git call: $arguments');
    final call = _calls[index];
    calls.add(arguments);
    expect(arguments, call.arguments);
    return call.result;
  }
}

final class _GitCall {
  const _GitCall({required this.arguments, required this.result});

  final List<String> arguments;
  final ProcessResult result;
}
