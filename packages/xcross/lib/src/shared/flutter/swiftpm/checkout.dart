import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/internal/host_symlink_capability.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/manifest.dart';
import 'package:xcross/src/shared/flutter/swiftpm/runtime.dart';

const String flutterFrameworkPackageName = 'FlutterFramework';
const String pluginsProductName = 'FlutterPluginsGenerated';

final class SwiftPmCheckout<T extends PlatformHostInterface> {
  SwiftPmCheckout(this.runtime);
  final SwiftPmRuntime<T> runtime;
  static const _stampKindDirectory = 'directory';

  static const _stampKindHardLink = 'hardlink';

  static const _stampKindForwarder = 'forwarder';

  static const _stampKindSymlink = 'symlink';

  /// Replaces mode-120000 checkout placeholders produced by Git for Windows.
  ///
  /// With symlink support ([HostSymlinkCapability]) every placeholder becomes
  /// a real symlink, restored by one `git checkout` per checkout; without it
  /// files become hard links (forwarding headers) and directories copies,
  /// through one PowerShell invocation per checkout. A stamp keyed on the
  /// checkout's HEAD records what was produced, so an unchanged checkout is
  /// verified with file-system checks alone and no process is spawned.
  Future<bool> materializeCheckoutSymlinks(
    String scratchPath, {
    String git = 'git',
    bool? symlinks,
  }) async {
    final gitExecutable = git == 'git'
        ? await runtime.runner.locateTool(git)
        : git;
    final checkouts = Directory(p.join(scratchPath, 'checkouts'));
    if (!checkouts.existsSync()) return false;
    var changed = false;
    await for (final repo in checkouts.list(followLinks: false)) {
      if (repo is! Directory) continue;
      changed =
          await materializeGitCheckoutSymlinks(
            repo.path,
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
    final useSymlinks = symlinks ?? await runtime.symlinks.probe();
    final root = p.normalize(p.absolute(repoPath));
    final stamp = File(
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
            '${runtime.host.name}\u0000$mode\u0000$identity',
          ),
        )
        .toString();

    final head = gitHeadIdentity(root);
    if (head != null && materializedLinksIntact(stamp, fingerprintOf(head))) {
      return false;
    }

    final index = await runtime.runner.run(git, [
      '-C',
      root,
      'ls-files',
      '-s',
      '-z',
    ]);
    if (index.exitCode != 0) {
      throw FlutterBuildError(
        'Could not inspect SwiftPM checkout $root: ${index.stderr}',
      );
    }
    final fingerprint = fingerprintOf(head ?? index.stdout);
    if (head == null && materializedLinksIntact(stamp, fingerprint)) {
      return false;
    }
    return materializeGitSymlinks(
      root,
      index.stdout,
      git,
      stamp,
      fingerprint,
      symlinks: useSymlinks,
    );
  }

  /// Contents of `HEAD` plus the ref it points at, read straight from the
  /// repository files, or null when they cannot be resolved that way.
  String? gitHeadIdentity(String root) {
    var gitDir = p.join(root, '.git');
    if (FileSystemEntity.isFileSync(gitDir)) {
      final pointer = File(gitDir).readAsStringSync().trim();
      if (!pointer.startsWith('gitdir:')) return null;
      gitDir = p.normalize(
        p.absolute(root, pointer.substring('gitdir:'.length).trim()),
      );
    }
    final headFile = File(p.join(gitDir, 'HEAD'));
    if (!headFile.existsSync()) return null;
    final head = headFile.readAsStringSync().trim();
    if (!head.startsWith('ref:')) return head;
    final ref = head.substring('ref:'.length).trim();
    final commonDirFile = File(p.join(gitDir, 'commondir'));
    final commonDir = commonDirFile.existsSync()
        ? p.normalize(
            p.absolute(gitDir, commonDirFile.readAsStringSync().trim()),
          )
        : gitDir;
    for (final dir in {gitDir, commonDir}) {
      final refFile = File(p.join(dir, ref));
      if (refFile.existsSync()) return '$head\n${refFile.readAsStringSync()}';
    }
    final packed = File(p.join(commonDir, 'packed-refs'));
    if (packed.existsSync()) {
      for (final line in packed.readAsLinesSync()) {
        if (line.endsWith(' $ref')) return '$head\n$line';
      }
    }
    return null;
  }

  /// Whether [stamp] carries [fingerprint] and every link it records still
  /// has the shape it was given.
  bool materializedLinksIntact(File stamp, String fingerprint) {
    if (!stamp.existsSync()) return false;
    final Object? decoded;
    try {
      decoded = jsonDecode(stamp.readAsStringSync());
    } on FormatException {
      return false;
    }
    if (decoded is! Map ||
        decoded['version'] != 3 ||
        decoded['fingerprint'] != fingerprint) {
      return false;
    }
    final links = decoded['links'];
    if (links is! List) return false;
    for (final entry in links) {
      if (entry is! Map) return false;
      final path = entry['path'];
      final kind = entry['kind'];
      final target = entry['target'];
      final directory = entry['directory'];
      if (path is! String || kind is! String || target is! String) return false;
      if (kind == _stampKindSymlink && !entry.containsKey('directory')) {
        return false;
      }
      if (directory != null && directory is! bool) return false;
      if (!linkIntact(path, kind, target, directory: directory as bool?)) {
        return false;
      }
    }
    return true;
  }

  bool linkIntact(String path, String kind, String target, {bool? directory}) {
    switch (kind) {
      case _stampKindSymlink:
        if (!FileSystemEntity.isLinkSync(path) ||
            Link(path).targetSync() != target) {
          return false;
        }
        final resolved = p.normalize(p.absolute(p.dirname(path), target));
        if (Directory(resolved).existsSync()) {
          return directory != false && Directory(path).existsSync();
        }
        if (File(resolved).existsSync()) {
          return directory != true && File(path).existsSync();
        }
        return directory == null;
      case _stampKindForwarder:
        final file = File(path);
        return !FileSystemEntity.isLinkSync(path) &&
            file.existsSync() &&
            file.readAsStringSync() == target;
      case _stampKindHardLink:
        final file = File(path);
        if (FileSystemEntity.isLinkSync(path) || !file.existsSync()) {
          return false;
        }
        // Git's placeholder holds the target text; anything else was
        // materialized.
        final placeholder = utf8.encode(target);
        return file.lengthSync() != placeholder.length ||
            !SwiftPmFilesystem.sameBytes(file.readAsBytesSync(), placeholder);
      case _stampKindDirectory:
        return !FileSystemEntity.isLinkSync(path) &&
            Directory(path).existsSync();
      default:
        return false;
    }
  }

  Future<bool> materializeGitSymlinks(
    String root,
    String index,
    String git,
    File stamp,
    String fingerprint, {
    required bool symlinks,
  }) async {
    final links = <String, String>{};
    for (final record in index.split('\u0000')) {
      final match = RegExp(
        r'^120000 ([0-9a-f]+) \d+\t(.*)$',
      ).firstMatch(record);
      if (match != null) {
        links[p.normalize(p.join(root, match[2]))] = match[1]!;
      }
    }

    final blobs = await readGitBlobs(root, links.values.toSet(), git);
    final targets = <String, String>{
      for (final link in links.entries)
        link.key: utf8
            .decode(blobs[link.value]!)
            .replaceFirst(RegExp(r'[\r\n]+$'), ''),
    };

    final resolved = <String, String>{};
    String resolve(String source, Set<String> chain) {
      if (!chain.add(source)) {
        throw FlutterBuildError('Symlink cycle in SwiftPM checkout: $source');
      }
      final targetText = targets[source]!;
      if (p.isAbsolute(targetText)) {
        throw FlutterBuildError(
          'Symlink escapes SwiftPM checkout: $source -> $targetText',
        );
      }
      final target = p.normalize(p.absolute(p.dirname(source), targetText));
      if (target != root && !p.isWithin(root, target)) {
        throw FlutterBuildError(
          'Symlink escapes SwiftPM checkout: $source -> $targetText',
        );
      }
      final result = links.containsKey(target)
          ? resolve(target, chain)
          : target;
      chain.remove(source);
      return result;
    }

    for (final link in links.keys) {
      resolved[link] = resolve(link, <String>{});
    }

    // A real symlink can preserve a missing optional example. A link used by
    // a declared package target, and every hard-link fallback, needs a target.
    for (final link in links.keys) {
      final target = resolved[link]!;
      if (!Directory(target).existsSync() &&
          !File(target).existsSync() &&
          (!symlinks || requiredPackageLink(root, link))) {
        throw FlutterBuildError(
          'Symlink target does not exist in SwiftPM checkout: $link -> '
          '$target',
        );
      }
    }

    final records = <Map<String, Object?>>[];
    final changed = symlinks
        ? await runtime.checkoutLinks.materializeAsSymlinks(
            root,
            links,
            targets,
            resolved,
            git,
            records,
          )
        : await runtime.hostPolicy.materializeFallback(
            runtime,
            root,
            links,
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

  bool requiredPackageLink(String root, String link) {
    final manifest = File(p.join(root, 'Package.swift'));
    if (!manifest.existsSync()) return true;
    final source = manifest.readAsStringSync();
    final calls = [
      for (final kind in ['.target', '.executableTarget', '.macro'])
        ...SwiftPmManifest.swiftCalls(source, kind),
    ];
    // Plugin builds never compile SwiftPM test targets. A checkout containing
    // only tests may therefore keep their dangling fixture/example links.
    if (calls.isEmpty) {
      return SwiftPmManifest.swiftCalls(source, '.testTarget').isEmpty;
    }
    for (final call in calls) {
      final name = SwiftPmManifest.namedString(call.text, 'name');
      final explicitPath = SwiftPmManifest.namedString(call.text, 'path');
      if (name == null && explicitPath == null) return true;
      final targetRoot = p.normalize(
        p.join(root, explicitPath ?? p.join('Sources', name)),
      );
      if (link != targetRoot && !p.isWithin(targetRoot, link)) continue;
      final relative = p.relative(link, from: targetRoot);
      final excluded = SwiftPmManifest.namedStringList(call.text, 'exclude');
      if (excluded.any(
        (path) => p.equals(relative, path) || p.isWithin(path, relative),
      )) {
        continue;
      }
      final sources = SwiftPmManifest.namedStringList(call.text, 'sources');
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

  Future<Map<String, List<int>>> readGitBlobs(
    String repoPath,
    Set<String> objectIds,
    String git,
  ) async {
    if (objectIds.isEmpty) return const {};
    final process = await runtime.runner.start(git, [
      '-C',
      repoPath,
      'cat-file',
      '--batch',
    ]);
    // Start draining before writing a single request. `cat-file --batch`
    // answers each object as it reads it, so its stdout fills up while this
    // process is still feeding stdin. A pipe buffer is finite (64 KiB on
    // Windows), so writing the whole request list first deadlocks as soon as
    // the replies outgrow it: git blocks writing output nobody is reading,
    // and this process blocks writing input git has stopped reading. A
    // checkout with enough symlinked headers (SDWebImage) reliably crosses
    // that line, which is what turned a CI build into a multi-hour hang.
    final outputFuture = process.stdout.fold<List<int>>(
      <int>[],
      (bytes, chunk) => bytes..addAll(chunk),
    );
    final errorFuture = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    // Backstop for any remaining way this child could stop making progress.
    // Reading local objects out of an existing checkout is a sub-second
    // operation, so a run this long is a hang, not slow work.
    const timeout = Duration(minutes: 5);
    var timedOut = false;
    final timer = Timer(timeout, () {
      timedOut = true;
      unawaited(runtime.runner.killTree(process));
    });
    final List<int> output;
    final String error;
    final int exitCode;
    try {
      for (final objectId in objectIds) {
        process.stdin.writeln(objectId);
      }
      // A killed child's stdin is a broken pipe; the failure that matters is
      // reported from the exit code below.
      try {
        await process.stdin.flush();
        await process.stdin.close();
      } on Object catch (_) {}
      exitCode = await process.exitCode;
      output = await outputFuture;
      error = await errorFuture;
    } finally {
      timer.cancel();
    }
    if (timedOut) {
      throw FlutterBuildError(
        'Timed out after ${timeout.inMinutes} minutes reading symlink targets '
        'in SwiftPM checkout $repoPath.',
      );
    }
    if (exitCode != 0) {
      throw FlutterBuildError(
        'Could not read symlink targets in SwiftPM checkout $repoPath: $error',
      );
    }

    var offset = 0;
    final blobs = <String, List<int>>{};
    for (final requested in objectIds) {
      final newline = output.indexOf(10, offset);
      if (newline < 0) {
        throw FlutterBuildError(
          'Malformed Git object response in SwiftPM checkout $repoPath.',
        );
      }
      final header = utf8.decode(output.sublist(offset, newline));
      final fields = header.split(' ');
      if (fields.length != 3 || fields[1] != 'blob') {
        throw FlutterBuildError(
          'Could not read symlink target $requested in SwiftPM checkout '
          '$repoPath: $header',
        );
      }
      final size = int.tryParse(fields[2]);
      if (size == null || size < 0 || newline + 1 + size >= output.length) {
        throw FlutterBuildError(
          'Malformed Git object response in SwiftPM checkout $repoPath.',
        );
      }
      final end = newline + 1 + size;
      blobs[requested] = output.sublist(newline + 1, end);
      if (output[end] != 10) {
        throw FlutterBuildError(
          'Malformed Git object response in SwiftPM checkout $repoPath.',
        );
      }
      offset = end + 1;
    }
    return blobs;
  }

  /// Windows source for a header placeholder that keeps one Clang file
  /// identity, or null when [link] is not a header.
  ///
  /// Packages publish umbrella directories by symlinking headers to a
  /// source tree, so the same header is reachable under two paths. Clang
  /// suppresses the second inclusion by file identity, and on POSIX a
  /// symlink shares one. Windows checkouts cannot use symlinks without
  /// elevation, and Clang treats the two names of a hard link as separate
  /// identities, so a header without an include guard is parsed twice and
  /// every declaration in it collides with itself. Forwarding to the
  /// target instead leaves exactly one file to parse under either path.
  static String? headerForwarder(String link, String target) {
    const headerExtensions = {'.h', '.hh', '.hpp', '.hxx', '.h++'};
    if (!headerExtensions.contains(p.extension(link).toLowerCase())) {
      return null;
    }
    final relative = p.relative(target, from: p.dirname(link));
    return '#include "${relative.replaceAll(r'\', '/')}"\n';
  }

  /// Git for Windows checks out symlink placeholders read-only.
  Future<void> clearPlaceholderAttributes(String path) =>
      runtime.hostPolicy.clearPlaceholderAttributes(runtime, path);
  Future<void> cloneGitPackage(
    String git,
    String url,
    String ref,
    String destination,
  ) async {
    final destDir = Directory(destination);
    final environment = runtime.processPolicy.swiftProcessEnvironment();
    // Last line of defence behind [nonInteractiveGitEnvironment]. That
    // environment cannot clear a *URL-scoped* helper — `credential
    // .https://github.com.helper` is a different key per host, so no fixed
    // reset covers them — and a helper that opens UI still blocks on a
    // build that has no one watching. A network stall does the same.
    // Generous enough that a cold clone of a large dependency finishes
    // (firebase-ios-sdk takes well under a minute on CI), short enough
    // that a stuck one is reported the same hour.
    const timeout = Duration(minutes: 10);
    // `core.symlinks=true` on every command, not just the clone: a later
    // `reset --hard` under the default `false` would see the real symlinks
    // as modified files and overwrite them with placeholders again.
    final gitConfig = await runtime.hostPolicy.cloneConfiguration(
      runtime.symlinks,
    );
    // Some packages keep their sources in a submodule (libwebp-Xcode vendors
    // webmproject/libwebp), so a submodule-less checkout compiles into
    // "unknown type name WebPDemuxer" once a dependent target imports it.
    Future<void> updateSubmodules() async {
      if (!File(p.join(destination, '.gitmodules')).existsSync()) return;
      await runtime.runner.runChecked(
        git,
        [
          ...gitConfig,
          '-C',
          destination,
          'submodule',
          'update',
          '--init',
          '--recursive',
          '--depth',
          '1',
        ],
        environment: environment,
        timeout: timeout,
        label: 'git submodule update ${p.basename(destination)}',
      );
    }

    if (File(p.join(destination, '.git')).existsSync() ||
        Directory(p.join(destination, '.git')).existsSync()) {
      final head = await runtime.runner.run(
        git,
        [...gitConfig, '-C', destination, 'rev-parse', '--verify', 'HEAD'],
        environment: environment,
        timeout: timeout,
      );
      if (head.exitCode == 0 &&
          head.stdout.trim().toLowerCase() == ref.toLowerCase()) {
        await runtime.runner.runChecked(
          git,
          [...gitConfig, '-C', destination, 'reset', '--hard', 'HEAD'],
          environment: environment,
          timeout: timeout,
          label: 'git reset vendored package',
        );
        await updateSubmodules();
        return;
      }
    }
    await runtime.filesystem.deleteEntity(destination);
    await destDir.parent.create(recursive: true);

    final shallow = await runtime.runner.run(
      git,
      [
        ...gitConfig,
        'clone',
        '--depth',
        '1',
        '--branch',
        ref,
        url,
        destination,
      ],
      environment: environment,
      timeout: timeout,
    );
    if (shallow.exitCode == 0) {
      await updateSubmodules();
      return;
    }

    await runtime.filesystem.deleteEntity(destination);
    await Directory(destination).create(recursive: true);
    final init = await runtime.runner.run(
      git,
      [...gitConfig, '-C', destination, 'init'],
      environment: environment,
      timeout: timeout,
    );
    final fetch = init.exitCode == 0
        ? await runtime.runner.run(
            git,
            [
              ...gitConfig,
              '-C',
              destination,
              'fetch',
              '--depth',
              '1',
              url,
              ref,
            ],
            environment: environment,
            timeout: timeout,
          )
        : init;
    final checkout = fetch.exitCode == 0
        ? await runtime.runner.run(
            git,
            [
              ...gitConfig,
              '-C',
              destination,
              'checkout',
              '--detach',
              'FETCH_HEAD',
            ],
            environment: environment,
            timeout: timeout,
          )
        : fetch;
    if (checkout.exitCode == 0) {
      await updateSubmodules();
      return;
    }

    await runtime.filesystem.deleteEntity(destination);
    await runtime.runner.runChecked(
      git,
      [...gitConfig, 'clone', url, destination],
      environment: environment,
      timeout: timeout,
      label: 'git clone $url',
    );
    await runtime.runner.runChecked(
      git,
      [...gitConfig, '-C', destination, 'checkout', ref],
      environment: environment,
      timeout: timeout,
      label: 'git checkout $ref',
    );
    await updateSubmodules();
  }

  Future<bool> normalizeVendoredPackageManifests(
    String packageDir, {
    required Set<String> consumedProducts,
    Map<String, List<String>>? fallbackSwiftModules,
    Future<String> Function(String manifest)? rewriteDependencies,
  }) async {
    var changed = false;
    final manifests = <File>[];
    await for (final entity in Directory(packageDir).list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name != 'Package.swift' &&
          !(name.startsWith('Package@') && name.endsWith('.swift'))) {
        continue;
      }
      manifests.add(entity);
    }
    Future<void> update(File manifest, String original, String updated) async {
      if (updated == original) return;
      await clearPlaceholderAttributes(manifest.path);
      await manifest.writeAsString(updated);
      // Vendoring restores the upstream manifest with `git reset --hard`
      // before each build, so these host fixes are re-applied every run and
      // land with a fresh timestamp even though the bytes never change.
      // SwiftPM invalidates a package's whole target set on its manifest
      // timestamp, so that alone recompiled the entire graph each build.
      await runtime.filesystem.stampByContent(manifest.path, updated);
      changed = true;
    }

    // Host fixes land on disk first so a nested `swift package resolve`
    // (needed when the parent's pins miss deps hidden behind `#if os(macOS)`)
    // sees the same manifests the final build will.
    for (final manifest in manifests) {
      final original = await manifest.readAsString();
      final normalized = await runtime.sourceFallback
          .synthesizeBinaryFallbackCompatibility(
            runtime.manifest.normalizeHostManifest(original),
            packageDir: packageDir,
            consumedProducts: consumedProducts,
            // The source-fallback block only activates where
            // [swiftProcessEnvironment] sets EXPERIMENTAL_SPM_BUILDS (Windows).
            // Elsewhere the binary product is used, its Swift half is not a
            // separate module, and injecting `import <fallback>` into consumers
            // fails with "no such module" (e.g. `SentrySwift` in sentry_flutter).
            fallbackSwiftModules: runtime.processPolicy.sourceFallbackActive
                ? fallbackSwiftModules
                : null,
          );
      await update(manifest, original, normalized);
    }
    if (rewriteDependencies != null) {
      for (final manifest in manifests) {
        final original = await manifest.readAsString();
        await update(manifest, original, await rewriteDependencies(original));
      }
    }
    return changed;
  }
}
