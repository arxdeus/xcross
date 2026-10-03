import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_containment.dart';
import 'package:xcross/src/shared/flutter/swiftpm/manifest_lexer.dart';

final class SwiftPmCheckoutGraph {
  const SwiftPmCheckoutGraph({required this.fileSystem});
  final SwiftPmArtifactFileSystem fileSystem;
  Map<String, String> indexLinks(String root, String index) {
    final links = <String, String>{};
    for (final record in index.split('\u0000')) {
      final match = RegExp(
        r'^120000 ([0-9a-f]+) \d+\t(.*)$',
      ).firstMatch(record);
      if (match == null) continue;
      final relative = match[2]!;
      final link = p.normalize(p.join(root, relative));
      if (relative.isEmpty ||
          p.isAbsolute(relative) ||
          !p.isWithin(root, link)) {
        throw FlutterBuildError(
          'Symlink index path escapes SwiftPM checkout: $relative',
          isSecurityFailure: true,
        );
      }
      links[link] = match[1]!;
    }
    return links;
  }

  Map<String, String> resolveTargets(String root, Map<String, String> targets) {
    final resolved = <String, String>{};
    String resolve(String source, Set<String> chain) {
      if (!chain.add(source)) {
        throw FlutterBuildError('Symlink cycle in SwiftPM checkout: $source');
      }
      final text = targets[source]!;
      if (p.isAbsolute(text)) {
        throw FlutterBuildError(
          'Symlink escapes SwiftPM checkout: $source -> $text',
          isSecurityFailure: true,
        );
      }
      final target = p.normalize(p.absolute(p.dirname(source), text));
      if (target != root && !p.isWithin(root, target)) {
        throw FlutterBuildError(
          'Symlink escapes SwiftPM checkout: $source -> $text',
          isSecurityFailure: true,
        );
      }
      final result = targets.containsKey(target)
          ? resolve(target, chain)
          : target;
      chain.remove(source);
      return result;
    }

    for (final link in targets.keys) {
      resolved[link] = resolve(link, <String>{});
    }
    return resolved;
  }

  void validateTargets(
    String root,
    Map<String, String> targets,
    Map<String, String> resolved, {
    required bool symlinks,
  }) {
    final containment = SwiftPmCheckoutContainment(fileSystem);
    for (final link in targets.keys) {
      final target = resolved[link]!;
      containment.validateDestination(root, link);
      containment.validateTarget(root, target);
      if (!fileSystem.directory(target).existsSync() &&
          !fileSystem.file(target).existsSync() &&
          (!symlinks || requiredPackageLink(root, link))) {
        throw FlutterBuildError(
          'Symlink target does not exist in SwiftPM checkout: $link -> $target',
        );
      }
    }
  }

  List<String> order(Map<String, String> links, Map<String, String> resolved) {
    final ordered = <String>[];
    final visiting = <String>{};
    void orderLink(String link) {
      if (ordered.contains(link)) return;
      if (!visiting.add(link)) {
        throw FlutterBuildError('Symlink cycle in SwiftPM checkout: $link');
      }
      final target = resolved[link]!;
      if (fileSystem.directory(target).existsSync()) {
        for (final nested in links.keys) {
          if (p.isWithin(target, nested)) orderLink(nested);
        }
      }
      visiting.remove(link);
      ordered.add(link);
    }

    for (final link in links.keys) {
      orderLink(link);
    }
    return ordered;
  }

  bool requiredPackageLink(String root, String link) {
    final manifest = fileSystem.file(p.join(root, 'Package.swift'));
    if (!manifest.existsSync()) return true;
    final source = manifest.readAsStringSync();
    final calls = [
      for (final kind in ['.target', '.executableTarget', '.macro'])
        ...SwiftPmManifestLexer.swiftCalls(source, kind),
    ];
    if (calls.isEmpty) {
      return SwiftPmManifestLexer.swiftCalls(source, '.testTarget').isEmpty;
    }
    for (final call in calls) {
      final name = SwiftPmManifestLexer.namedString(call.text, 'name');
      final explicitPath = SwiftPmManifestLexer.namedString(call.text, 'path');
      if (name == null && explicitPath == null) return true;
      final targetRoot = p.normalize(
        p.join(root, explicitPath ?? p.join('Sources', name)),
      );
      if (link != targetRoot && !p.isWithin(targetRoot, link)) continue;
      final relative = p.relative(link, from: targetRoot);
      final excluded = SwiftPmManifestLexer.namedStringList(
        call.text,
        'exclude',
      );
      if (excluded.any(
        (path) => p.equals(relative, path) || p.isWithin(path, relative),
      )) {
        continue;
      }
      final sources = SwiftPmManifestLexer.namedStringList(
        call.text,
        'sources',
      );
      if (sources.isEmpty ||
          sources.any(
            (path) =>
                p.equals(relative, path) ||
                p.isWithin(path, relative) ||
                p.isWithin(relative, path),
          )) {
        return true;
      }
      for (final resource in RegExp(
        r'\.(?:process|copy)\(\s*"([^"]+)"',
      ).allMatches(call.text)) {
        final path = resource[1]!;
        if (p.equals(relative, path) ||
            p.isWithin(path, relative) ||
            p.isWithin(relative, path)) {
          return true;
        }
      }
    }
    return false;
  }
}
