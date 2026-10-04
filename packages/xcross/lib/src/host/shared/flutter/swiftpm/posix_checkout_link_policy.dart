import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_graph.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_link_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';

@internal
final class PosixSwiftPmCheckoutGitPolicy implements SwiftPmCheckoutGitPolicy {
  const PosixSwiftPmCheckoutGitPolicy();
  @override
  String linkText(String text) => text;
  @override
  List<String> get checkoutArguments => const [];
  @override
  Future<List<String>> cloneConfiguration() async => const [];
}

@internal
final class PosixSwiftPmCheckoutFallback<T extends PlatformHostInterface>
    implements SwiftPmCheckoutFallback {
  const PosixSwiftPmCheckoutFallback({
    required this.fileSystem,
    required this.filesystem,
    required this.graph,
  });
  final SwiftPmArtifactFileSystem fileSystem;
  final SwiftPmFilesystem<T> filesystem;
  final SwiftPmCheckoutGraph graph;
  @override
  Future<bool> materialize(
    String root,
    Map<String, String> links,
    Map<String, String> targets,
    Map<String, String> resolved,
    List<Map<String, Object?>> records,
  ) async {
    var changed = false;
    graph.validateTargets(root, targets, resolved, symlinks: false);
    for (final link in graph.order(links, resolved)) {
      final target = resolved[link]!;
      if (fileSystem.directory(target).existsSync()) {
        records.add({'path': link, 'kind': 'directory', 'target': target});
        await filesystem.deleteUnless(link, FileSystemEntityType.directory);
        changed = await filesystem.syncDirectory(target, link) || changed;
      } else {
        records.add({
          'path': link,
          'kind': 'hardlink',
          'target': targets[link],
        });
        changed =
            await filesystem.syncFile(fileSystem.file(target), link) || changed;
      }
    }
    return changed;
  }
}
