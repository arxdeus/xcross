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
            'xcross-symlink-materialization-v3\u0000'
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
    return materialized;
  }

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
