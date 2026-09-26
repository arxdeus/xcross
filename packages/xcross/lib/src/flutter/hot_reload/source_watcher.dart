import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Tracks which `lib/` `.dart` files changed between compiles, so a hot reload
/// only recompiles what the user actually edited.
final class SourceWatcher {
  SourceWatcher(
    this.projectRoot, {
    String? packageConfig,
    this.additionalFiles = const [],
  }) : packageConfig =
           packageConfig ?? '$projectRoot/.dart_tool/package_config.json';

  final String packageConfig;
  final List<String> additionalFiles;
  final Set<String> _retryUris = {};

  /// Flutter project root directory.
  final String projectRoot;

  // Content hash of each file at the last compile, the change-detection
  // baseline.
  final Map<String, int> _hashes = {};

  /// Every `lib/` `.dart` file, as absolute paths. Scoped to `lib/` since
  /// `test/`/`bin/`/`tool/` pull in non-runtime deps that would balloon the
  /// compile.
  List<String> dartFiles() {
    final files = <String>{
      for (final path in additionalFiles)
        if (File(path).existsSync()) p.normalize(File(path).absolute.path),
    };
    final pending = _searchRoots();
    final visited = <String>{};
    while (pending.isNotEmpty) {
      final List<FileSystemEntity> entries;
      try {
        final directory = pending.removeLast();
        if (!visited.add(p.normalize(directory.absolute.path))) continue;
        entries = directory.listSync(followLinks: false);
      } on FileSystemException {
        continue;
      }
      for (final entity in entries) {
        final name = _basename(entity);
        if (entity is Directory) {
          if (!name.startsWith('.') && name != 'build') pending.add(entity);
        } else if (entity is File && name.endsWith('.dart')) {
          files.add(p.normalize(entity.absolute.path));
        }
      }
    }
    return files.toList()..sort();
  }

  /// Record the current content hash of every `lib/` `.dart` file as the
  /// baseline for [changedFileUris].
  void snapshot() {
    _hashes.clear();
    _retryUris.clear();
    for (final path in dartFiles()) {
      if (_contentHash(path) case final hash?) _hashes[path] = hash;
    }
  }

  /// `lib/` `.dart` files whose content changed since the last snapshot, as
  /// `file://` URIs. NOT a pure query: it advances the baseline as it walks,
  /// so a second call returns empty.
  List<String> changedFileUris() {
    final changed = <String>{..._retryUris};
    _retryUris.clear();
    final paths = dartFiles().toSet();
    for (final path in paths) {
      final hash = _contentHash(path);
      if (hash == null || _hashes[path] == hash) continue;
      _hashes[path] = hash;
      changed.add(Uri.file(path).toString());
    }
    for (final path in _hashes.keys.toList()) {
      if (paths.contains(path) || File(path).existsSync()) continue;
      _hashes.remove(path);
      changed.add(Uri.file(path).toString());
    }
    return changed.toList()..sort();
  }

  void restoreInvalidations(Iterable<String> uris) => _retryUris.addAll(uris);

  List<Directory> _searchRoots() {
    final roots = <Directory>[if (_searchRoot() case final root?) root];
    final config = File(packageConfig).absolute;
    try {
      final document = jsonDecode(config.readAsStringSync());
      if (document is! Map<String, dynamic>) return roots;
      final packages = document['packages'];
      if (packages is! List) return roots;
      final cache =
          _configPath(document['pubCache'], config.uri) ??
          Platform.environment['PUB_CACHE'] ??
          p.join(Platform.environment['HOME'] ?? '', '.pub-cache');
      final flutterRoot = _configPath(document['flutterRoot'], config.uri);
      String? flutterPackages;
      for (final package in packages) {
        if (package case {'name': 'flutter', 'rootUri': final String root}) {
          final uri = config.uri.resolve(root);
          if (uri.scheme == 'file') {
            flutterPackages = p.dirname(p.normalize(uri.toFilePath()));
          }
        }
      }
      for (final package in packages) {
        if (package is! Map<String, dynamic>) continue;
        final root = package['rootUri'];
        final packageUri = package['packageUri'] ?? 'lib/';
        if (root is! String || packageUri is! String) continue;
        final rootUri = config.uri.resolve(root);
        if (rootUri.scheme != 'file') continue;
        final rootPath = p.normalize(rootUri.toFilePath());
        if (p.isWithin(p.absolute(cache), rootPath) ||
            (flutterRoot != null && p.isWithin(flutterRoot, rootPath)) ||
            (flutterPackages != null &&
                (p.equals(flutterPackages, rootPath) ||
                    p.isWithin(flutterPackages, rootPath)))) {
          continue;
        }
        final uri = Uri.directory(rootPath).resolve(packageUri);
        if (uri.scheme == 'file') roots.add(Directory.fromUri(uri));
      }
    } on FileSystemException {
      return roots;
    } on FormatException {
      return roots;
    }
    return roots;
  }

  static String? _configPath(Object? value, Uri configUri) {
    if (value is! String) return null;
    final uri = configUri.resolve(value);
    return uri.scheme == 'file' ? p.normalize(uri.toFilePath()) : null;
  }

  // `<projectRoot>/lib`, falling back to the project root, or null if
  // neither exists.
  Directory? _searchRoot() {
    for (final path in ['$projectRoot/lib', projectRoot]) {
      final dir = Directory(path);
      if (dir.existsSync()) return dir;
    }
    return null;
  }

  static String _basename(FileSystemEntity entity) =>
      entity.uri.pathSegments.where((s) => s.isNotEmpty).last;

  // Null when the file cannot be read (deleted mid-walk, permissions).
  static int? _contentHash(String path) {
    try {
      return _fnv1a(File(path).readAsBytesSync());
    } on Object catch (_) {
      return null;
    }
  }

  // 64-bit FNV-1a hash (mtime is unreliable over virtiofs). Offset basis
  // 0xCBF2_9CE4_8422_2325, prime 0x100_0000_01B3.
  static int _fnv1a(List<int> bytes) {
    // ignore: avoid_js_rounded_ints
    var hash = 0xCBF2_9CE4_8422_2325;
    for (final byte in bytes) {
      hash = (hash ^ byte) * 0x100_0000_01B3;
    }
    return hash & 0x7FFF_FFFF_FFFF_FFFF;
  }
}
