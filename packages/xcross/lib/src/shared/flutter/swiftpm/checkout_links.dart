import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/runtime.dart';

const String flutterFrameworkPackageName = 'FlutterFramework';
const String pluginsProductName = 'FlutterPluginsGenerated';

final class SwiftPmCheckoutLinks<T extends PlatformHostInterface> {
  SwiftPmCheckoutLinks(this.runtime);
  final SwiftPmRuntime<T> runtime;
  static const _stampKindDirectory = 'directory';
  static const _stampKindHardLink = 'hardlink';
  static const _stampKindForwarder = 'forwarder';
  static const _stampKindSymlink = 'symlink';

  /// Turns every placeholder into a real symlink carrying Git's own target
  /// text, so the checkout matches its index under `core.symlinks=true` and
  /// later `git reset`/`checkout` runs leave it alone.
  ///
  /// Git restores the links in one `checkout` of the affected paths; it
  /// handles read-only placeholders and, with every target already on disk,
  /// picks the right link kind. Anything it still got wrong is recreated
  /// here directly.
  Future<bool> materializeAsSymlinks(
    String root,
    Map<String, String> links,
    Map<String, String> targets,
    Map<String, String> resolved,
    String git,
    List<Map<String, Object?>> records,
  ) async {
    String linkText(String link) =>
        runtime.hostPolicy.checkoutLinkText(targets[link]!);
    bool intact(String link) =>
        runtime.checkout.linkIntact(link, _stampKindSymlink, linkText(link));

    final pending = [
      for (final link in links.keys)
        if (!intact(link)) link,
    ];
    for (final link in links.keys) {
      records.add({
        'path': link,
        'kind': _stampKindSymlink,
        'target': linkText(link),
        'directory': Directory(resolved[link]!).existsSync()
            ? true
            : File(resolved[link]!).existsSync()
            ? false
            : null,
      });
    }
    if (pending.isEmpty) return false;

    final checkout = await runtime.runner.start(git, [
      '-c',
      'core.symlinks=true',
      ...runtime.hostPolicy.checkoutArguments,
      '-C',
      root,
      'checkout',
      '--force',
      '--pathspec-from-file=-',
      '--pathspec-file-nul',
      '--',
    ]);
    checkout.stdin.write(
      pending.map((link) => p.relative(link, from: root)).join('\u0000'),
    );
    await checkout.stdin.close();
    final stderr = await checkout.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    await checkout.stdout.drain<void>();
    if (await checkout.exitCode != 0) {
      throw FlutterBuildError(
        'Could not restore symlinks in SwiftPM checkout $root: $stderr',
      );
    }

    for (final link in pending) {
      if (intact(link)) continue;
      final type = FileSystemEntity.typeSync(link, followLinks: false);
      if (type == FileSystemEntityType.link) {
        Link(link).deleteSync();
      } else if (type == FileSystemEntityType.directory) {
        Directory(link).deleteSync(recursive: true);
      } else if (type != FileSystemEntityType.notFound) {
        await runtime.checkout.clearPlaceholderAttributes(link);
        File(link).deleteSync();
      }
      createRelativeLink(link, linkText(link));
      if (!intact(link)) {
        throw FlutterBuildError(
          'Could not create symlink in SwiftPM checkout: $link -> '
          '${linkText(link)}',
        );
      }
    }
    return true;
  }

  /// `Link.create` decides between a file and a directory symlink by looking
  /// at the target relative to the working directory, so a relative target
  /// is only typed correctly from the link's own directory.
  void createRelativeLink(String link, String target) =>
      runtime.hostPolicy.createRelativeLink(link, target);
}
