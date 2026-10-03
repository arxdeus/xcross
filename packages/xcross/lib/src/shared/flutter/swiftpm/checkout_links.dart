import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_attributes.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_link_creator.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_link_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_stamp.dart';

final class SwiftPmCheckoutLinks<T extends PlatformHostInterface> {
  const SwiftPmCheckoutLinks({
    required this.runner,
    required this.fileSystem,
    required this.stamps,
    required this.attributes,
    required this.linkCreator,
    required this.policy,
  });
  final ProcessRunner<T> runner;
  final SwiftPmArtifactFileSystem fileSystem;
  final SwiftPmCheckoutStampValidator stamps;
  final SwiftPmCheckoutAttributes attributes;
  final SwiftPmCheckoutLinkCreator linkCreator;
  final SwiftPmCheckoutGitPolicy policy;
  static const _stampKindSymlink = 'symlink';
  Future<bool> materializeAsSymlinks(
    String root,
    Map<String, String> links,
    Map<String, String> targets,
    Map<String, String> resolved,
    String git,
    List<Map<String, Object?>> records,
  ) async {
    String linkText(String link) => policy.linkText(targets[link]!);
    bool intact(String link) =>
        stamps.linkIntact(link, _stampKindSymlink, linkText(link));

    final pending = [
      for (final link in links.keys)
        if (!intact(link)) link,
    ];
    for (final link in links.keys) {
      records.add({
        'path': link,
        'kind': _stampKindSymlink,
        'target': linkText(link),
        'directory': fileSystem.directory(resolved[link]!).existsSync()
            ? true
            : fileSystem.file(resolved[link]!).existsSync()
            ? false
            : null,
      });
    }
    if (pending.isEmpty) return false;

    final checkout = await runner.start(git, [
      '-c',
      'core.symlinks=true',
      ...policy.checkoutArguments,
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
    checkout.stdin.write(
      pending.map((link) => p.relative(link, from: root)).join('\u0000'),
    );
    await checkout.stdin.close();
    final stderr = await stderrFuture;
    await outputFuture;
    if (await checkout.exitCode != 0) {
      throw FlutterBuildError(
        'Could not restore symlinks in SwiftPM checkout $root: $stderr',
      );
    }

    for (final link in pending) {
      if (intact(link)) continue;
      final type = fileSystem.typeSync(link, followLinks: false);
      if (type == FileSystemEntityType.link) {
        fileSystem.link(link).deleteSync();
      } else if (type == FileSystemEntityType.directory) {
        fileSystem.directory(link).deleteSync(recursive: true);
      } else if (type != FileSystemEntityType.notFound) {
        await attributes.clear(link);
        fileSystem.file(link).deleteSync();
      }
      linkCreator.create(link, linkText(link));
      if (!intact(link)) {
        throw FlutterBuildError(
          'Could not create symlink in SwiftPM checkout: $link -> '
          '${linkText(link)}',
        );
      }
    }
    return true;
  }
}
