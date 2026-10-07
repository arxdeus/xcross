import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_manifest_normalizer.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_source_normalizer.dart';

@internal
const String manifestCompilerName = 'xcross-manifest-swiftc';
@internal
const String manifestCompilerVariable = 'XCROSS_MANIFEST_COMPILER';
@internal
const String manifestPolicyVariable = 'XCROSS_MANIFEST_POLICY';
@internal
const String manifestCompilerLogVariable = 'XCROSS_MANIFEST_COMPILER_LOG';

@internal
typedef SwiftPmManifestCompilerRun =
    Future<int> Function(String executable, List<String> arguments);

@internal
@immutable
final class SwiftPmManifestCompilerConfiguration {
  const SwiftPmManifestCompilerConfiguration({
    required this.compiler,
    required this.cacheRoot,
    required this.policy,
    this.consumedProducts = const {},
  });

  factory SwiftPmManifestCompilerConfiguration.fromJson(
    Map<String, Object?> json,
  ) => SwiftPmManifestCompilerConfiguration(
    compiler: json['compiler']! as String,
    cacheRoot: json['cacheRoot']! as String,
    policy: json['policy']! as String,
    consumedProducts: {
      for (final MapEntry(:key, :value)
          in ((json['consumedProducts'] as Map?) ?? const {}).entries)
        key as String: (value as List).cast<String>(),
    },
  );

  final String compiler;
  final String cacheRoot;
  final String policy;
  final Map<String, List<String>> consumedProducts;

  Map<String, Object?> toJson() => {
    'compiler': compiler,
    'cacheRoot': cacheRoot,
    'policy': policy,
    'consumedProducts': {
      for (final key in consumedProducts.keys.toList()..sort())
        key: consumedProducts[key],
    },
  };
}

@internal
@immutable
final class SwiftPmManifestOverlay {
  const SwiftPmManifestOverlay({
    required this.overlayPath,
    required this.manifestPath,
    required this.contentsPath,
  });
  final String overlayPath;
  final String manifestPath;
  final String contentsPath;
}

@internal
final class SwiftPmManifestCompiler {
  SwiftPmManifestCompiler({
    required this.fileSystem,
    required this.policy,
    required this.sourceNormalizer,
    required this.run,
    this.log,
  });

  final SwiftPmArtifactFileSystem fileSystem;
  final SwiftPmVendoredManifestPolicy policy;
  final SwiftPmHostSourceNormalizer sourceNormalizer;
  final SwiftPmManifestCompilerRun run;
  final void Function(String line)? log;

  Future<int> compile(
    List<String> arguments,
    SwiftPmManifestCompilerConfiguration configuration,
  ) async {
    final overlay = readOverlay(arguments);
    if (overlay == null) {
      log?.call('pass');
      return run(configuration.compiler, arguments);
    }
    final contents = fileSystem.file(overlay.contentsPath);
    final original = await contents.readAsString();
    final patched = await rewrite(
      original,
      manifestPath: overlay.manifestPath,
      configuration: configuration,
    );
    if (patched != original) await contents.writeAsString(patched);
    final output = outputPath(arguments);
    final key = output == null || arguments.any(_uncacheable)
        ? null
        : cacheKey(
            arguments,
            overlay: overlay,
            manifest: patched,
            configuration: configuration,
          );
    if (key == null) {
      log?.call('uncached ${overlay.manifestPath}');
      return run(configuration.compiler, arguments);
    }
    final entry = fileSystem.file(
      p.join(configuration.cacheRoot, 'manifest-compiler', key),
    );
    if (entry.existsSync()) {
      try {
        await entry.copy(output!);
        log?.call('hit $key ${overlay.manifestPath}');
        return 0;
      } on FileSystemException {
        log?.call('unreadable $key');
      }
    }
    final code = await run(configuration.compiler, arguments);
    log?.call('miss $key ${overlay.manifestPath} exit=$code');
    if (code == 0) await _publish(output!, entry);
    return code;
  }

  Future<String> rewrite(
    String manifest, {
    required String manifestPath,
    required SwiftPmManifestCompilerConfiguration configuration,
  }) async {
    final directory = p.dirname(manifestPath);
    if (directory == manifestPath ||
        fileSystem.typeSync(p.join(directory, 'Package.swift')) !=
            FileSystemEntityType.file) {
      return policy.normalizeHostManifest(manifest);
    }
    final products = configuration.consumedProducts[p.normalize(directory)];
    final normalized = await policy.normalize(
      manifest,
      packageDir: directory,
      consumedProducts: {...?products},
    );
    return sourceNormalizer.removeMissingResources(normalized, directory);
  }

  SwiftPmManifestOverlay? readOverlay(List<String> arguments) {
    SwiftPmManifestOverlay? found;
    for (var index = 0; index < arguments.length; index++) {
      if (arguments[index] != '-vfsoverlay') continue;
      if (found != null || index + 1 >= arguments.length) return null;
      final overlayPath = arguments[++index];
      final Object? decoded;
      try {
        decoded = jsonDecode(fileSystem.file(overlayPath).readAsStringSync());
      } on FormatException {
        return null;
      } on FileSystemException {
        return null;
      }
      if (decoded case {
        'roots': [
          {
            'type': 'file',
            'name': final String manifestPath,
            'external-contents': final String contentsPath,
          },
        ],
      } when fileSystem.typeSync(contentsPath) == FileSystemEntityType.file) {
        found = SwiftPmManifestOverlay(
          overlayPath: overlayPath,
          manifestPath: manifestPath,
          contentsPath: contentsPath,
        );
      } else {
        return null;
      }
    }
    return found;
  }

  String? outputPath(List<String> arguments) {
    String? output;
    for (var index = 0; index < arguments.length - 1; index++) {
      if (arguments[index] != '-o') continue;
      if (output != null) return null;
      output = arguments[index + 1];
    }
    return output;
  }

  String cacheKey(
    List<String> arguments, {
    required SwiftPmManifestOverlay overlay,
    required String manifest,
    required SwiftPmManifestCompilerConfiguration configuration,
  }) {
    final locationSensitive = manifest.contains('#file');
    final normalized = <String>[];
    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      if (argument == '-o' && index + 1 < arguments.length) {
        normalized.addAll([
          argument,
          p.basename(arguments[++index]).replaceAll(RegExp(r'\.exe$'), ''),
        ]);
      } else if (argument == overlay.overlayPath) {
        normalized.add('<overlay>');
      } else if (argument == overlay.contentsPath) {
        normalized.add('<contents>');
      } else if (argument == overlay.manifestPath && !locationSensitive) {
        normalized.add('<manifest>');
      } else {
        normalized.add(argument);
      }
    }
    final compiler = fileSystem.file(configuration.compiler);
    final stat = compiler.statSync();
    return sha256
        .convert(
          utf8.encode(
            jsonEncode({
              'policy': configuration.policy,
              'compiler': [
                configuration.compiler,
                stat.size,
                stat.modified.millisecondsSinceEpoch,
              ],
              'arguments': normalized,
              'manifest': manifest,
              if (locationSensitive) 'location': overlay.manifestPath,
            }),
          ),
        )
        .toString();
  }

  Future<void> _publish(String output, File entry) async {
    final temporary = fileSystem.file(
      '${entry.path}.$pid-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await fileSystem.directory(p.dirname(entry.path)).create(recursive: true);
      await fileSystem.file(output).copy(temporary.path);
      await temporary.rename(entry.path);
    } on FileSystemException {
      log?.call('unpublished ${entry.path}');
    } finally {
      if (temporary.existsSync()) await temporary.delete();
    }
  }

  static bool _uncacheable(String argument) =>
      argument == '-serialize-diagnostics-path';
}

@internal
Future<void> writeManifestCompilerFile(
  PlatformHostInterface host,
  String path,
  String contents,
) async {
  final file = host.fileSystem.file(host.paths.ioPath(path));
  if (file.existsSync() && await file.readAsString() == contents) return;
  final temporary = host.fileSystem.file(
    host.paths.ioPath('$path.$pid-${DateTime.now().microsecondsSinceEpoch}'),
  );
  await temporary.writeAsString(contents, flush: true);
  await temporary.rename(file.path);
}

@internal
Future<void> copyManifestCompilerExecutable(
  PlatformHostInterface host,
  String source,
  String destination,
) async {
  final from = host.fileSystem.file(host.paths.ioPath(source));
  final to = host.fileSystem.file(host.paths.ioPath(destination));
  if (to.existsSync() && to.lengthSync() == from.lengthSync()) {
    final left = sha256.convert(await from.readAsBytes());
    final right = sha256.convert(await to.readAsBytes());
    if (left == right) return;
  }
  final temporary = host.fileSystem.file(
    host.paths.ioPath(
      '$destination.$pid-${DateTime.now().microsecondsSinceEpoch}',
    ),
  );
  await from.copy(temporary.path);
  await temporary.rename(to.path);
}

@internal
String manifestCompilerPolicyDigest(Map<String, Object?> identity) =>
    sha256.convert(utf8.encode(jsonEncode(identity))).toString();
