import 'dart:io';

import 'package:meta/meta.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/update/internal/update_process.dart';

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
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
    });
typedef CreateTempDirectory = Future<Directory> Function(String prefix);
typedef DeleteDirectory = Future<void> Function(Directory directory);

final class GitUpdateRefResolver {
  GitUpdateRefResolver({
    RunGitProcess? run,
    CreateTempDirectory? createTempDirectory,
    DeleteDirectory? deleteDirectory,
  }) : _run = run ?? runUpdateProcess,
       _createTempDirectory =
           createTempDirectory ?? _defaultCreateTempDirectory,
       _deleteDirectory = deleteDirectory ?? _defaultDeleteDirectory;

  static const repoUrl = 'https://github.com/arxdeus/xcross.git';

  final RunGitProcess _run;
  final CreateTempDirectory _createTempDirectory;
  final DeleteDirectory _deleteDirectory;

  Future<GitUpdateRef> resolve(String ref) async {
    if (_wildcard.hasMatch(ref)) {
      throw XcrossError(
        'invalid update ref "$ref": wildcard patterns are not supported; '
        'provide a concrete tag, branch, full ref, or full 40-character '
        'commit SHA',
      );
    }
    if (ref.startsWith('refs/tags/')) {
      return _resolveExact(ref, GitUpdateRefKind.tag, 'refs/tags/');
    }
    if (ref.startsWith('refs/heads/')) {
      return _resolveExact(ref, GitUpdateRefKind.branch, 'refs/heads/');
    }

    final tagRef = _tagRef(ref);
    final tagCommitSha = await _lookupCommitSha(tagRef, preferPeeledTag: true);
    if (tagCommitSha != null) {
      return GitUpdateRef(
        kind: GitUpdateRefKind.tag,
        displayName: _displayName(tagRef, 'refs/tags/'),
        fetchRef: tagRef,
        commitSha: tagCommitSha,
      );
    }

    final branchRef = _branchRef(ref);
    final branchCommitSha = await _lookupCommitSha(branchRef);
    if (branchCommitSha != null) {
      return GitUpdateRef(
        kind: GitUpdateRefKind.branch,
        displayName: _displayName(branchRef, 'refs/heads/'),
        fetchRef: branchRef,
        commitSha: branchCommitSha,
      );
    }

    if (_hex.hasMatch(ref) && !_fullCommitSha.hasMatch(ref)) {
      throw XcrossError(
        'failed to resolve update ref "$ref": abbreviated commit SHAs are '
        'not supported; provide the full 40-character commit SHA',
      );
    }

    final commitSha = await _fetchCommit(ref);
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
    final commitSha = await _resolveExactCommitSha(ref, kind: kind);
    if (commitSha == null) {
      throw XcrossError(
        'failed to resolve update ref "$ref": git did not return an exact '
        'full 40-character commit SHA',
      );
    }
    return GitUpdateRef(
      kind: kind,
      displayName: _displayName(ref, prefix),
      fetchRef: ref,
      commitSha: commitSha,
    );
  }

  Future<String?> _resolveExactCommitSha(
    String ref, {
    required GitUpdateRefKind kind,
  }) {
    return kind == GitUpdateRefKind.tag
        ? _lookupCommitSha(ref, preferPeeledTag: true)
        : _lookupCommitSha(ref);
  }

  Future<String?> _lookupCommitSha(
    String ref, {
    bool preferPeeledTag = false,
  }) async {
    final result = await _run('git', [
      'ls-remote',
      repoUrl,
      ref,
      if (preferPeeledTag) '$ref^{}',
    ]);
    if (result.exitCode != 0) return null;
    return _parseLsRemoteCommitSha(
      '${result.stdout}',
      ref,
      preferPeeledTag: preferPeeledTag,
    );
  }

  Future<String> _fetchCommit(String ref) async {
    final directory = await _createTempDirectory('xcross-update-ref-');
    try {
      final init = await _run('git', [
        'init',
      ], workingDirectory: directory.path);
      if (init.exitCode != 0) {
        throw _gitFailure('initialize update ref repository', ref, init);
      }

      final fetch = await _run('git', [
        'fetch',
        '--depth=1',
        repoUrl,
        ref,
      ], workingDirectory: directory.path);
      if (fetch.exitCode != 0) {
        throw _gitFailure('resolve update ref', ref, fetch);
      }

      final head = await _run('git', [
        'rev-parse',
        'FETCH_HEAD',
      ], workingDirectory: directory.path);
      if (head.exitCode != 0) {
        throw _gitFailure('read fetched update commit', ref, head);
      }

      final commitSha = '${head.stdout}'.trim();
      if (!_fullCommitSha.hasMatch(commitSha)) {
        throw XcrossError(
          'failed to resolve update ref "$ref": git did not return a full '
          '40-character commit SHA',
        );
      }
      return commitSha;
    } finally {
      try {
        await _deleteDirectory(directory);
      } on Object {
        // Temporary clone cleanup is best effort and must not hide the
        // original resolve result or failure.
      }
    }
  }

  XcrossError _gitFailure(String action, String ref, ProcessResult result) {
    final stderr = '${result.stderr}'.trim();
    return XcrossError(
      stderr.isEmpty
          ? 'failed to $action "$ref"'
          : 'failed to $action "$ref": $stderr',
    );
  }

  static String _displayName(String ref, String prefix) =>
      ref.substring(prefix.length);

  static String? _parseLsRemoteCommitSha(
    String output,
    String ref, {
    bool preferPeeledTag = false,
  }) {
    String? direct;
    String? peeled;
    for (final line in output.split('\n').map((line) => line.trim())) {
      if (line.isEmpty) continue;
      final fields = line.split(RegExp(r'\s+'));
      if (fields.length != 2 || !_fullCommitSha.hasMatch(fields[0])) continue;
      if (fields[1] == ref) direct = fields[0];
      if (preferPeeledTag && fields[1] == '$ref^{}') peeled = fields[0];
    }
    return peeled ?? direct;
  }

  static Future<Directory> _defaultCreateTempDirectory(String prefix) =>
      Directory.systemTemp.createTemp(prefix);

  static Future<void> _defaultDeleteDirectory(Directory directory) =>
      directory.delete(recursive: true);

  static String _tagRef(String ref) => 'refs/tags/$ref';

  static String _branchRef(String ref) => 'refs/heads/$ref';

  static final _wildcard = RegExp(r'[?*\[]');
  static final _hex = RegExp(r'^[0-9a-fA-F]+$');
  static final _fullCommitSha = RegExp(r'^[0-9a-fA-F]{40}$');
}
