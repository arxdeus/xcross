import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/runtime.dart';

const String flutterFrameworkPackageName = 'FlutterFramework';
const String pluginsProductName = 'FlutterPluginsGenerated';

final class SwiftPmFilesystem<T extends PlatformHostInterface> {
  SwiftPmFilesystem(this.runtime);
  final SwiftPmRuntime<T> runtime;
  Future<void> stageFlutterFramework(String source, String destination, {required bool copy}) async {
    if(copy) {
      await deleteUnless(destination, FileSystemEntityType.directory);
      await syncDirectory(source, destination);
    } else {
      await deleteEntity(destination);
      await Link(destination).create(source);
    }
  }


  /// Writes [content] to [path] only when it differs.
  ///
  /// SwiftPM invalidates on timestamps, so rewriting identical generated
  /// files would recompile the whole plugin graph on every run.
  ///
  /// Skipping the write is not enough on its own. Several of these files are
  /// staged, reset, or regenerated from scratch earlier in the same build, so
  /// the write is genuinely necessary yet still produces the bytes the last
  /// build compiled. The timestamp is therefore derived from the content, so
  /// identical output always presents SwiftPM with an identical timestamp.
  Future<void> writeStable(String path, String content) async {
    final file = File(path);
    if (!(file.existsSync() && await file.readAsString() == content)) {
      await writeAtomic(path, utf8.encode(content));
    }
    await stampByContent(path, content);
  }

  /// Sets [path]'s modification time to a function of [content].
  ///
  /// For a file that must be rewritten on every run because something else
  /// reverts it first, "write only when changed" cannot keep the timestamp
  /// stable. Deriving the timestamp from the bytes can: the same content
  /// always yields the same timestamp, so SwiftPM sees no change, while new
  /// content still moves it.
  ///
  /// Failures are ignored. A timestamp that cannot be set costs a rebuild,
  /// which is the behaviour this avoids, not a broken build.
  Future<void> stampByContent(String path, String content) =>
      stampByContentBytes(path, utf8.encode(content));

  /// [_stampByContent] for content already encoded as bytes.
  Future<void> stampByContentBytes(String path, List<int> bytes) async {
    try {
      final digest = sha256.convert(bytes).bytes;
      // A fixed, arbitrary epoch plus a digest-derived offset. The offset is
      // bounded to roughly a decade so the result is always a valid, plainly
      // historical timestamp rather than something a tool might reject.
      final offset =
          ((digest[0] << 24) | (digest[1] << 16) | (digest[2] << 8) | digest[3])
              .toUnsigned(32) %
          const Duration(days: 3650).inSeconds;
      await File(
        path,
      ).setLastModified(DateTime.utc(2010).add(Duration(seconds: offset)));
    } on Object {
      // Deliberately ignored: see above.
    }
  }

  Future<void> writeAtomic(String path, List<int> bytes) async {
    final temporary = File(
      '$path.xcross-$pid-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(path);
    } finally {
      if (temporary.existsSync()) await temporary.delete();
    }
  }

  int fileBytes(String path) {
    final file = File(path);
    return file.existsSync() ? file.lengthSync() : 0;
  }

  int directoryBytes(String path) {
    final directory = Directory(ioPath(path));
    if (!directory.existsSync()) return 0;
    var bytes = 0;
    for (final entity in directory.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File) bytes += entity.lengthSync();
    }
    return bytes;
  }

  String ioPath(String path) => runtime.host.paths.ioPath(path);

  void traceBinaryOperation({
    required String target,
    required String operation,
    required int elapsedMilliseconds,
    required int attempt,
    int archiveBytes = 0,
    int extractedBytes = 0,
  }) {
    runtime.runner.log.logTrace(
      'binary target=$target operation=$operation '
      'archive_bytes=$archiveBytes extracted_bytes=$extractedBytes '
      'elapsed_ms=$elapsedMilliseconds attempt=$attempt',
    );
  }

  /// Copies [source] to [destination], applying [transform] when it elects
  /// the file, and skipping the write when the destination already matches.
  ///
  /// The skip preserves destination timestamps, which SwiftPM invalidates
  /// on, so unchanged files stay warm in its incremental state. Files the
  /// transform declines are copied as raw bytes, so binaries are never
  /// decoded.
  Future<bool> syncFile(
    File source,
    String destination, {
    SwiftPmSourceTransform? transform,
  }) async {
    List<int> bytes = await source.readAsBytes();
    final rewrite = transform?.call(source.path);
    if (rewrite != null) {
      bytes = utf8.encode(rewrite(utf8.decode(bytes)));
    }
    final existing = File(destination);
    if (existing.existsSync() &&
        SwiftPmFilesystem.sameBytes(await existing.readAsBytes(), bytes)) {
      return false;
    }
    await existing.writeAsBytes(bytes);
    // Staging re-copies plugin sources on every build, and a later repair
    // pass rewrites some of them, so a file can be legitimately written
    // twice per build while ending at the same bytes it had before. SwiftPM
    // invalidates on timestamps, so without a content-derived stamp those
    // rewrites recompile the target, and everything downstream of it, on
    // every incremental build.
    await stampByContentBytes(destination, bytes);
    return true;
  }

  static bool sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> copyResolvedArtifactTree(
    String source,
    String destination, {
    String? artifactRoot,
    bool Function(String name)? includeTopLevel,
  }) async {
    final ioSource = ioPath(source);
    final ioDestination = ioPath(destination);
    final root = artifactRoot == null
        ? p.normalize(p.absolute(ioSource))
        : ioPath(artifactRoot);
    await Directory(ioDestination).create(recursive: true);
    await for (final entity in Directory(ioSource).list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (artifactRoot == null &&
          includeTopLevel != null &&
          !includeTopLevel(name)) {
        continue;
      }
      final target = p.join(destination, name);

      final resolved = p.normalize(
        p.absolute(
          entity is Link ? entity.resolveSymbolicLinksSync() : entity.path,
        ),
      );
      if (!p.equals(root, resolved) && !p.isWithin(root, resolved)) {
        throw FlutterBuildError(
          'SwiftPM binary artifact link escapes its artifact root',
          isSecurityFailure: true,
        );
      }
      if (Directory(resolved).existsSync()) {
        await copyResolvedArtifactTree(
          resolved,
          target,
          artifactRoot: root,
          includeTopLevel: includeTopLevel,
        );
      } else if (File(resolved).existsSync()) {
        await File(resolved).copy(target);
      } else {
        throw FlutterBuildError(
          'SwiftPM binary artifact contains an unresolved link',
          isSecurityFailure: true,
        );
      }
    }
  }

  /// Mirrors [source] into [destination], resolving links to their

  /// targets, rewriting only differing files, and pruning entries the
  /// source no longer has. [preserve] names top-level entries the caller
  /// owns; [excludedSourcePath] guards against copying a destination that
  /// lives inside its own source.
  Future<bool> syncDirectory(
    String source,
    String destination, {
    Set<String> preserve = const {},
    String? excludedSourcePath,
    SwiftPmSourceTransform? transform,
  }) async {
    final absoluteSource = p.normalize(p.absolute(source));
    final absoluteDestination = p.normalize(p.absolute(destination));
    if (p.equals(absoluteSource, absoluteDestination)) return false;
    var changed = !Directory(destination).existsSync();
    final excluded = excludedSourcePath == null
        ? (p.isWithin(absoluteSource, absoluteDestination)
              ? absoluteDestination
              : null)
        : p.normalize(p.absolute(excludedSourcePath));
    await Directory(destination).create(recursive: true);

    final expected = <String>{...preserve};
    await for (final entity in Directory(source).list(followLinks: false)) {
      if (excluded != null &&
          p.equals(p.normalize(p.absolute(entity.path)), excluded)) {
        continue;
      }
      final name = p.basename(entity.path);
      if (preserve.contains(name)) continue;
      expected.add(name);
      final destinationPath = p.join(destination, name);
      final resolved = entity is Link
          ? entity.resolveSymbolicLinksSync()
          : entity.path;
      if (Directory(resolved).existsSync()) {
        final existingType = FileSystemEntity.typeSync(
          destinationPath,
          followLinks: false,
        );
        await deleteUnless(destinationPath, FileSystemEntityType.directory);
        changed =
            await syncDirectory(
              resolved,
              destinationPath,
              excludedSourcePath: excluded,
              transform: transform,
            ) ||
            existingType != FileSystemEntityType.directory ||
            changed;
      } else {
        final existingType = FileSystemEntity.typeSync(
          destinationPath,
          followLinks: false,
        );
        await deleteUnless(destinationPath, FileSystemEntityType.file);
        changed =
            await syncFile(
              File(resolved),
              destinationPath,
              transform: transform,
            ) ||
            existingType != FileSystemEntityType.file ||
            changed;
      }
    }

    await for (final entity in Directory(
      destination,
    ).list(followLinks: false)) {
      if (!expected.contains(p.basename(entity.path))) {
        await deleteEntity(entity.path);
        changed = true;
      }
    }
    return changed;
  }

  static List<String> windowsCopyArguments(String source, String destination) =>
      [
        source,
        destination,
        '/E',
        '/R:0',
        '/W:0',
        '/MT:8',
        '/NFL',
        '/NDL',
        '/NJH',
        '/NJS',
        '/NP',
      ];

  Future<void> deleteUnless(String path, FileSystemEntityType keep) async {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound || type == keep) return;
    await deleteEntity(path);
  }

  Future<void> deleteEntity(String path) async {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      await Link(path).delete();
    } else if (type == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: true);
    } else if (type == FileSystemEntityType.file) {
      await File(path).delete();
    }
  }

  /// Makes the staged Swift package appear directly beside FlutterFramework,
  /// so every plugin's conventional `../FlutterFramework` dependency resolves
  /// to the same package path. Directory junctions avoid Windows symlink
  /// privilege requirements.
  Future<void> createDirectoryAlias(String alias, String target) async {
    await deleteEntity(alias);
    await runtime.artifactFileSystem.createAlias(alias, p.absolute(target));
  }

  static String jsonPath(String path) => path.replaceAll(r'\', '/');

  /// Forward-slash-safe absolute path for interpolation into a Swift string
  /// literal on every host.
  static String swiftPath(String path) =>
      SwiftPmFilesystem.jsonPath(p.absolute(path));

  /// A pub package name with underscores replaced by hyphens — SwiftPM's own
  /// convention for a plugin's SPM library product name (used as the
  /// CFBundleIdentifier for dynamic products, which can't contain
  /// underscores). The `package:` argument stays underscored, matching the
  /// plugin's own unmodified `Package(name: ...)`.
  static String hyphenate(String name) => name.replaceAll('_', '-');
}

typedef SwiftPmSourceTransform =
    String Function(String content)? Function(String path);
