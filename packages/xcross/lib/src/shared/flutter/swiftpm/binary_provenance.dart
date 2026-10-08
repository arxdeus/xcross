import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:cli_kit/shared/process/process_models.dart';
import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/shared/flutter/build/swiftpm_binary_target.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_policy.dart';

@internal
const String flutterFrameworkPackageName = 'FlutterFramework';
@internal
const String pluginsProductName = 'FlutterPluginsGenerated';

@internal
final class SwiftPmBinaryProvenance<T extends PlatformHostInterface> {
  SwiftPmBinaryProvenance({
    required this.artifactFileSystem,
    required this.host,
    required this.hostPolicy,
    required this.runner,
  });
  final SwiftPmArtifactFileSystem artifactFileSystem;
  final T host;
  final SwiftPmHostPolicy hostPolicy;
  final ProcessRunner<T> runner;
  static Map<String, String> dependencyRefsFromPackageResolved(String output) {
    final resolved = jsonDecode(output) as Map<String, dynamic>;
    return {
      for (final pinValue
          in resolved['pins'] as List<Object?>? ?? const <Object?>[])
        if (pinValue case {
          'location': final String location,
          'state': {'revision': final String revision},
        })
          SwiftPmBinaryProvenance.canonicalGitUrl(location): revision,
    };
  }

  static String canonicalGitUrl(String url) {
    var canonical = url.replaceFirst(RegExp(r'/+$'), '');
    if (canonical.toLowerCase().endsWith('.git')) {
      canonical = canonical.substring(0, canonical.length - 4);
    }
    final parsed = Uri.tryParse(canonical);
    if (parsed == null || !parsed.hasScheme) return canonical;
    return parsed
        .replace(
          scheme: parsed.scheme.toLowerCase(),
          host: parsed.host.toLowerCase(),
        )
        .toString();
  }

  Future<String> dependencyEvaluationKey(
    String manifest,
    String packageDirectory,
  ) async {
    final variants = <String>[];
    final directory = artifactFileSystem.directory(packageDirectory);
    if (directory.existsSync()) {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (name.startsWith('Package@') && name.endsWith('.swift')) {
          variants.add('$name\u0000${await entity.readAsString()}');
        }
      }
    }
    variants.sort();
    return sha256
        .convert(
          utf8.encode(
            [
              'xcross-dependency-evaluation-v1',
              manifest,
              ...variants,
            ].join('\u0000'),
          ),
        )
        .toString();
  }

  static List<SwiftPmBinaryArtifactProvenance> scanBinaryArtifactProvenance({
    required String packageIdentity,
    required String manifestPath,
    required String manifest,
  }) => [
    for (final target in SwiftPmBinaryTargetManifest.discover(manifest))
      SwiftPmBinaryArtifactProvenance(
        packageIdentity: packageIdentity,
        target: target,
        manifestPath: manifestPath,
      ),
  ];

  SwiftPmBinaryArtifactProvenance? matchBinaryArtifactProvenance({
    required String artifactPath,
    required String artifactsRoot,
    required Iterable<SwiftPmBinaryArtifactProvenance> provenance,
  }) {
    final relative = p.split(p.relative(artifactPath, from: artifactsRoot));
    if (relative.length < 2 || swiftPmComponent(relative.first) == 'extract') {
      return null;
    }
    final identity = swiftPmComponent(relative[0]);
    final target = swiftPmComponent(relative[1]);
    final matches = provenance
        .where(
          (candidate) =>
              swiftPmComponent(candidate.packageIdentity) == identity &&
              swiftPmComponent(candidate.target.name) == target,
        )
        .toList();
    return matches.length == 1 ? matches.single : null;
  }

  String swiftPmComponent(String value) => hostPolicy.artifactIdentity(value);

  String binaryArtifactAttemptKey(SwiftPmBinaryArtifactProvenance provenance) =>
      [
        swiftPmComponent(provenance.packageIdentity),
        swiftPmComponent(provenance.target.name),
        provenance.target.checksum.toLowerCase(),
      ].join('\u0000');

  /// Manifest files tracked anywhere in a SwiftPM checkout, without walking
  /// its working tree. Git for Windows handles its index with
  /// `core.longpaths=true`, so irrelevant deep assets cannot make discovery
  /// fail with MAX_PATH.
  Future<List<File>> trackedPackageManifestFiles(
    String packageDirectory, {
    Future<CapturedProcess> Function(String, List<String>)? runProcess,
  }) async {
    final result = await (runProcess ?? runner.run)('git', [
      '-c',
      'core.longpaths=true',
      '-C',
      packageDirectory,
      'ls-files',
      '-z',
      '--',
      'Package.swift',
      'Package@*.swift',
      ':(glob)**/Package.swift',
      ':(glob)**/Package@*.swift',
    ]);
    if (result.exitCode != 0) {
      throw FlutterBuildError(
        'Could not inspect SwiftPM checkout $packageDirectory: '
        '${result.stderr.trim()}',
      );
    }
    final paths =
        result.stdout
            .split('\u0000')
            .where((path) => path.isNotEmpty)
            .map(
              (path) => artifactFileSystem.file(
                p.join(packageDirectory, p.fromUri(path)),
              ),
            )
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    return paths;
  }
}
