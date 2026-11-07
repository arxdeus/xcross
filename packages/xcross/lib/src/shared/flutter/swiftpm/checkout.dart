import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/host/shared/flutter/swiftpm/host_symlink_capability.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_git_repository.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_graph.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_link_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_links.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_stamp.dart';
import 'package:xcross/src/shared/flutter/swiftpm/process_policy.dart';

@internal
final class SwiftPmCheckout<T extends PlatformHostInterface> {
  const SwiftPmCheckout({
    required this.runner,
    required this.fileSystem,
    required this.symlinks,
    required this.stamps,
    required this.graph,
    required this.repository,
    required this.links,
    required this.fallback,
  });
  final ProcessRunner<T> runner;
  final SwiftPmArtifactFileSystem fileSystem;
  final HostSymlinkCapability symlinks;
  final SwiftPmCheckoutStampValidator stamps;
  final SwiftPmCheckoutGraph graph;
  final SwiftPmGitRepository<T> repository;
  final SwiftPmCheckoutLinks<T> links;
  final SwiftPmCheckoutFallback fallback;
  Future<bool> materializeCheckoutSymlinks(
    String scratchPath, {
    String git = 'git',
    bool? symlinks,
  }) async {
    final gitExecutable = git == 'git' ? await runner.locateTool(git) : git;
    final checkouts = fileSystem.directory(p.join(scratchPath, 'checkouts'));
    if (!checkouts.existsSync()) return false;
    var changed = false;
    await for (final repo in checkouts.list(followLinks: false)) {
      if (repo is! Directory) continue;
      changed =
          await materializeGitCheckoutSymlinks(
            fileSystem.processPath(repo.path),
            git: gitExecutable,
            stampDir: p.join(scratchPath, '.xcross-symlinks'),
            symlinks: symlinks,
          ) ||
          changed;
    }
    return changed;
  }

  Future<bool> materializeGitCheckoutSymlinks(
    String repoPath, {
    String git = 'git',
    String? stampDir,
    bool? symlinks,
  }) async {
    final useSymlinks = symlinks ?? await this.symlinks.probe();
    final root = p.normalize(p.absolute(repoPath));
    final stamp = fileSystem.file(
      p.join(
        stampDir ?? p.join(p.dirname(root), '.xcross-symlinks'),
        sha256.convert(utf8.encode(root)).toString(),
      ),
    );
    final mode = useSymlinks ? 'symlink' : 'hardlink';
    String fingerprintOf(String identity) => sha256
        .convert(
          utf8.encode(
            'xcross-symlink-materialization-v4\u0000'
            '${runner.host.name}\u0000$mode\u0000$identity',
          ),
        )
        .toString();

    final head = repository.gitHeadIdentity(root);
    if (head != null &&
        stamps.materializedLinksIntact(
          stamp,
          fingerprintOf(head),
          root: root,
        )) {
      return false;
    }

    final index = await runner.run(git, ['-C', root, 'ls-files', '-s', '-z']);
    if (index.exitCode != 0) {
      throw FlutterBuildError(
        'Could not inspect SwiftPM checkout $root: ${index.stderr}',
      );
    }
    final fingerprint = fingerprintOf(head ?? index.stdout);
    if (head == null &&
        stamps.materializedLinksIntact(stamp, fingerprint, root: root)) {
      return false;
    }
    final materialized = await materializeGitSymlinks(
      root,
      index.stdout,
      git,
      stamp,
      fingerprint,
      symlinks: useSymlinks,
    );
    final bool renormalized;
    try {
      renormalized = await renormalizeLineEndings(root, git);
    } on Object {
      // The stamp would skip the next attempt.
      if (stamp.existsSync()) stamp.deleteSync();
      rethrow;
    }
    return materialized || renormalized;
  }

  /// Rewrites files a `core.autocrlf=true` checkout converted to CRLF.
  ///
  /// Checkouts cached before xcross pinned
  /// [SwiftPmProcessPolicy.checkoutLineEndingConfiguration] keep their CRLF
  /// files, because SwiftPM never rewrites an unchanged path. Git reports
  /// such a file as `i/lf w/crlf`; checking it out again under the pinned
  /// settings restores the repository bytes. Paths whose attributes ask
  /// for CRLF stay as they are, as on macOS. The fingerprint version in
  /// [materializeGitCheckoutSymlinks] makes this run once per checkout
  /// revision.
  Future<bool> renormalizeLineEndings(String root, String git) async {
    final lineEndings = SwiftPmProcessPolicy.checkoutLineEndingArguments;
    final listing = await runner.run(git, [
      ...lineEndings,
      '-C',
      root,
      'ls-files',
      '--eol',
      '-z',
    ]);
    if (listing.exitCode != 0) {
      throw FlutterBuildError(
        'Could not inspect line endings in SwiftPM checkout $root: '
        '${listing.stderr}',
      );
    }
    final paths = crlfConvertedPaths(listing.stdout);
    if (paths.isEmpty) return false;
    final checkout = await runner.start(git, [
      ...lineEndings,
      '-C',
      root,
      'checkout',
      '--force',
      '--pathspec-from-file=-',
      '--pathspec-file-nul',
      '--',
    ]);
    final stderrFuture = checkout.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    final outputFuture = checkout.stdout.drain<void>();
    checkout.stdin.write(paths.join('\u0000'));
    await checkout.stdin.close();
    final stderr = await stderrFuture;
    await outputFuture;
    if (await checkout.exitCode != 0) {
      throw FlutterBuildError(
        'Could not restore line endings in SwiftPM checkout $root: $stderr',
      );
    }
    return true;
  }

  /// Paths in `git ls-files --eol -z` output stored with LF but checked out
  /// with CRLF without their attributes asking for it.
  static List<String> crlfConvertedPaths(String listing) => [
    for (final entry in listing.split('\u0000'))
      if (entry.indexOf('\t') case final tab when tab > 0)
        if (entry.substring(0, tab).split(RegExp(r'\s+')) case [
          'i/lf',
          'w/crlf',
          ...final attributes,
        ] when !attributes.join(' ').contains('eol=crlf'))
          entry.substring(tab + 1),
  ];

  Future<bool> materializeGitSymlinks(
    String root,
    String index,
    String git,
    File stamp,
    String fingerprint, {
    required bool symlinks,
  }) async {
    final indexLinks = graph.indexLinks(root, index);
    final blobs = await repository.readGitBlobs(
      root,
      indexLinks.values.toSet(),
      git,
    );
    final targets = <String, String>{
      for (final link in indexLinks.entries)
        link.key: utf8
            .decode(blobs[link.value]!)
            .replaceFirst(RegExp(r'[\r\n]+$'), ''),
    };
    final resolved = graph.resolveTargets(root, targets);
    graph.validateTargets(root, targets, resolved, symlinks: symlinks);
    final records = <Map<String, Object?>>[];
    final changed = symlinks
        ? await links.materializeAsSymlinks(
            root,
            indexLinks,
            targets,
            resolved,
            git,
            records,
          )
        : await fallback.materialize(
            root,
            indexLinks,
            targets,
            resolved,
            records,
          );

    await stamp.parent.create(recursive: true);
    await stamp.writeAsString(
      jsonEncode({'version': 3, 'fingerprint': fingerprint, 'links': records}),
    );
    return changed;
  }
}
