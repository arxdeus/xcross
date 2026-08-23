import 'dart:io';

import 'package:meta/meta.dart';
import 'package:xcross/src/errors.dart';

enum GitUpdateRefKind { tag, branch, commit }

@immutable
final class GitUpdateRef {
  const GitUpdateRef({
    required this.kind,
    required this.displayName,
    required this.fetchRef,
    required this.commitSha,
  });

  final GitUpdateRefKind kind;
  final String displayName;
  final String fetchRef;
  final String commitSha;
}

typedef RunGitProcess =
    Future<ProcessResult> Function(String executable, List<String> arguments);

final class GitUpdateRefResolver {
  GitUpdateRefResolver({RunGitProcess? run}) : _run = run ?? _defaultRun;

  static const repoUrl = 'https://github.com/arxdeus/xcross.git';

  final RunGitProcess _run;

  Future<GitUpdateRef> resolve(String ref) async {
    if (ref.startsWith('refs/tags/')) {
      return _resolveExact(ref, GitUpdateRefKind.tag, 'refs/tags/');
    }
    if (ref.startsWith('refs/heads/')) {
      return _resolveExact(ref, GitUpdateRefKind.branch, 'refs/heads/');
    }

    final tagRef = _tagRef(ref);
    final tagProbe = await _probe(tagRef);
    if (tagProbe != null) {
      return GitUpdateRef(
        kind: GitUpdateRefKind.tag,
        displayName: _displayName(tagRef, 'refs/tags/'),
        fetchRef: tagRef,
        commitSha: tagProbe.commitSha,
      );
    }

    final branchRef = _branchRef(ref);
    final branchProbe = await _probe(branchRef);
    if (branchProbe != null) {
      return GitUpdateRef(
        kind: GitUpdateRefKind.branch,
        displayName: _displayName(branchRef, 'refs/heads/'),
        fetchRef: branchRef,
        commitSha: branchProbe.commitSha,
      );
    }

    final fallback = await _lsRemote(ref);
    if (fallback.exitCode != 0) {
      final stderr = '${fallback.stderr}'.trim();
      throw XcrossError(
        stderr.isEmpty
            ? 'failed to resolve update ref "$ref"'
            : 'failed to resolve update ref "$ref": $stderr',
      );
    }

    final commitSha = _commitSha('${fallback.stdout}');
    if (commitSha == null) {
      throw XcrossError(
        'failed to resolve update ref "$ref": empty git output',
      );
    }

    return GitUpdateRef(
      kind: GitUpdateRefKind.commit,
      displayName: ref,
      fetchRef: ref,
      commitSha: commitSha,
    );
  }

  Future<GitUpdateRef> _resolveExact(
    String ref,
    GitUpdateRefKind kind,
    String prefix,
  ) async {
    final probe = await _probe(ref);
    if (probe == null) {
      throw XcrossError(
        'failed to resolve update ref "$ref": empty git output',
      );
    }
    return GitUpdateRef(
      kind: kind,
      displayName: _displayName(ref, prefix),
      fetchRef: ref,
      commitSha: probe.commitSha,
    );
  }

  Future<_ProbeResult?> _probe(String ref) async {
    final result = await _lsRemote(ref);
    if (result.exitCode != 0) return null;
    final commitSha = _commitSha('${result.stdout}');
    return commitSha == null ? null : _ProbeResult(commitSha);
  }

  Future<ProcessResult> _lsRemote(String ref) =>
      _run('git', ['ls-remote', repoUrl, ref]);

  static Future<ProcessResult> _defaultRun(
    String executable,
    List<String> arguments,
  ) => Process.run(executable, arguments);

  static String _tagRef(String ref) => 'refs/tags/$ref';

  static String _branchRef(String ref) => 'refs/heads/$ref';

  static String _displayName(String ref, String prefix) =>
      ref.substring(prefix.length);

  static String? _commitSha(String output) {
    final lines = output
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    for (final line in lines) {
      final fields = line.split(RegExp(r'\s+'));
      if (fields.length >= 2 && fields[1].endsWith('^{}')) return fields[0];
    }
    if (lines.isEmpty) return null;
    final fields = lines.first.split(RegExp(r'\s+'));
    return fields.isEmpty ? null : fields.first;
  }
}

final class _ProbeResult {
  const _ProbeResult(this.commitSha);

  final String commitSha;
}
