import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:xcross/src/flutter/build/swiftpm_binary_artifact_store.dart';
import 'package:xcross/src/flutter/build/swiftpm_binary_target.dart';
import 'package:xcross/src/flutter/errors.dart';

typedef DownloadBinaryArchive =
    Future<void> Function(Uri url, File destination, int maximumBytes);

const _archiveByteLimitMessage =
    'SwiftPM binary artifact exceeds compressed archive byte limit';

typedef StartBinaryCopy =
    Future<BinaryCopyProcess> Function(
      String executable,
      List<String> arguments,
    );

bool isWindowsMountPointReparseOutput(String output) =>
    RegExp(r'0x0*a0000003\b', caseSensitive: false).hasMatch(output);

abstract interface class BinaryCopyProcess {
  Future<int> get exitCode;
  Stream<List<int>> get stdout;
  Stream<List<int>> get stderr;
  bool kill();
}

final class SwiftPmBinaryArtifactPublication {
  SwiftPmBinaryArtifactPublication._(this.nonce);

  static final reused = SwiftPmBinaryArtifactPublication._(null);
  factory SwiftPmBinaryArtifactPublication.published() =>
      SwiftPmBinaryArtifactPublication._(
        '${pid}_${DateTime.now().microsecondsSinceEpoch}',
      );

  final String? nonce;

  @override
  bool operator ==(Object other) =>
      other is SwiftPmBinaryArtifactPublication &&
      ((nonce == null && other.nonce == null) ||
          (nonce != null && other.nonce != null));

  @override
  int get hashCode => nonce == null ? 0 : 1;
}

final class _IoBinaryCopyProcess implements BinaryCopyProcess {
  const _IoBinaryCopyProcess(this.process);

  final Process process;

  @override
  Future<int> get exitCode => process.exitCode;

  @override
  Stream<List<int>> get stdout => process.stdout;

  @override
  Stream<List<int>> get stderr => process.stderr;

  @override
  bool kill() => process.kill();
}

final class SwiftPmPreparedBinaryArtifact {
  const SwiftPmPreparedBinaryArtifact({
    required this.target,
    required this.entry,
  });

  final SwiftPmRemoteBinaryTarget target;
  final SwiftPmBinaryArtifactEntry entry;
}

final class SwiftPmBinaryArtifactPreparer {
  SwiftPmBinaryArtifactPreparer({
    required SwiftPmBinaryArtifactStore store,
    DownloadBinaryArchive? download,
    int maxEntries = 100000,
    int maxExpandedBytes = 4294967296,
    int maxArchiveBytes = 536870912,
  }) : _store = store,
       _download = download ?? _defaultDownload,
       _maxEntries = maxEntries,
       _maxExpandedBytes = maxExpandedBytes,
       _maxArchiveBytes = maxArchiveBytes {
    if (maxEntries < 1) {
      throw ArgumentError.value(maxEntries, 'maxEntries', 'must be positive');
    }
    if (maxExpandedBytes < 0) {
      throw ArgumentError.value(
        maxExpandedBytes,
        'maxExpandedBytes',
        'must not be negative',
      );
    }
    if (maxArchiveBytes < 0) {
      throw ArgumentError.value(
        maxArchiveBytes,
        'maxArchiveBytes',
        'must not be negative',
      );
    }
  }

  static final Map<String, Future<void>> _destinationTails = {};

  final SwiftPmBinaryArtifactStore _store;
  final DownloadBinaryArchive _download;
  final int _maxEntries;
  final int _maxExpandedBytes;
  final int _maxArchiveBytes;

  Future<void> createBinaryArtifactJunction({
    required String alias,
    required String target,
  }) => _withDestinationLock(alias, () async {
    if (!await _completeEntryContaining(target)) {
      throw FileSystemException(
        'SwiftPM binary artifact target is not a complete store entry',
        target,
      );
    }
    await _removeBinaryArtifactAlias(alias);
    final absoluteAlias = p.normalize(p.absolute(alias));
    final resolvedTarget = p.normalize(
      p.absolute(await Directory(target).resolveSymbolicLinks()),
    );
    final nonce = '${pid}_${DateTime.now().microsecondsSinceEpoch}';
    final temporaryAlias = '$absoluteAlias.xcross-junction-$nonce';
    var published = false;
    try {
      await _createAlias(temporaryAlias, resolvedTarget);
      if (!await _isAliasTo(temporaryAlias, resolvedTarget)) {
        throw FileSystemException(
          'SwiftPM binary artifact junction has an unexpected type or target',
          temporaryAlias,
        );
      }
      await Directory(temporaryAlias).rename(absoluteAlias);
      published = true;
      if (!await _isAliasTo(absoluteAlias, resolvedTarget)) {
        throw FileSystemException(
          'Published SwiftPM binary artifact alias has an unexpected type or target',
          absoluteAlias,
        );
      }
      await _writeAliasMarker(absoluteAlias, resolvedTarget, nonce);
    } catch (_) {
      final cleanup = published ? absoluteAlias : temporaryAlias;
      if (await _isAliasTo(cleanup, resolvedTarget)) {
        await _deleteVerifiedAlias(cleanup);
      }
      rethrow;
    }
  });

  Future<void> removeBinaryArtifactAlias(String alias) =>
      _withDestinationLock(alias, () => _removeBinaryArtifactAlias(alias));

  Future<void> _removeBinaryArtifactAlias(String alias) async {
    final absoluteAlias = p.normalize(p.absolute(alias));
    final marker = File(_aliasMarkerPath(absoluteAlias));
    final type = FileSystemEntity.typeSync(absoluteAlias, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      if (marker.existsSync()) await marker.delete();
      return;
    }
    final ownership = await _managedAliasTarget(absoluteAlias, marker);
    if (ownership == null ||
        !await _isAliasTo(absoluteAlias, ownership.target)) {
      throw FileSystemException(
        'Refusing to remove an unowned or changed SwiftPM binary artifact path',
        absoluteAlias,
      );
    }
    final revalidated = await _managedAliasTarget(absoluteAlias, marker);
    if (revalidated != ownership ||
        !await _isAliasTo(absoluteAlias, ownership.target)) {
      throw FileSystemException(
        'Refusing to remove a changed SwiftPM binary artifact alias',
        absoluteAlias,
      );
    }
    await _deleteVerifiedAlias(absoluteAlias);
    final markerAfterDelete = await _managedAliasTarget(absoluteAlias, marker);
    if (markerAfterDelete != null &&
        markerAfterDelete.target == ownership.target &&
        markerAfterDelete.nonce == ownership.nonce) {
      await marker.delete();
    }
  }

  Future<void> _createAlias(String alias, String target) async {
    if (Platform.isWindows) {
      final result =
          await ProcessRunner.run(await ProcessRunner.locateTool('cmd.exe'), [
            '/c',
            'mklink',
            '/J',
            p.windows.normalize(alias),
            p.windows.normalize(target),
          ]);
      if (result.exitCode != 0) {
        throw FileSystemException(
          'Could not create SwiftPM binary artifact junction: '
          '${_boundedDiagnostic(result.stderr)}',
          alias,
        );
      }
      return;
    }
    await Link(alias).create(target);
  }

  Future<bool> _isAliasTo(String alias, String target) async {
    final type = FileSystemEntity.typeSync(alias, followLinks: false);
    if (Platform.isWindows) {
      if (type != FileSystemEntityType.directory &&
          type != FileSystemEntityType.link) {
        return false;
      }
      if (!await _isWindowsMountPoint(alias)) return false;
    } else if (type != FileSystemEntityType.link) {
      return false;
    }
    try {
      final resolved = p.normalize(
        p.absolute(await Directory(alias).resolveSymbolicLinks()),
      );
      return _pathKey(resolved) == _pathKey(p.normalize(p.absolute(target)));
    } on FileSystemException {
      return false;
    }
  }

  Future<bool> _isWindowsMountPoint(String alias) async {
    final result = await ProcessRunner.run(
      await ProcessRunner.locateTool('fsutil.exe'),
      ['reparsepoint', 'query', alias],
    );
    return result.exitCode == 0 &&
        isWindowsMountPointReparseOutput(result.stdout);
  }

  Future<void> _deleteVerifiedAlias(String alias) async {
    if (Platform.isWindows) {
      final result = await ProcessRunner.run(
        await ProcessRunner.locateTool('cmd.exe'),
        ['/c', 'rmdir', alias],
      );
      if (result.exitCode != 0) {
        throw FileSystemException(
          'Could not remove SwiftPM binary artifact junction: '
          '${_boundedDiagnostic(result.stderr)}',
          alias,
        );
      }
      return;
    }
    await Link(alias).delete();
  }

  Future<void> _writeAliasMarker(
    String alias,
    String target,
    String nonce,
  ) async {
    final marker = File(_aliasMarkerPath(alias));
    final temporary = File('${marker.path}.tmp-$nonce');
    try {
      await temporary.writeAsString(
        jsonEncode({'alias': alias, 'target': target, 'nonce': nonce}),
        flush: true,
      );
      await temporary.rename(marker.path);
    } catch (_) {
      if (temporary.existsSync()) await temporary.delete();
      rethrow;
    }
  }

  String _aliasMarkerPath(String alias) => '$alias.xcross-alias.json';

  Future<({String target, String nonce})?> _managedAliasTarget(
    String alias,
    File marker,
  ) async {
    if (!marker.existsSync()) return null;
    try {
      final value = jsonDecode(await marker.readAsString());
      if (value is! Map<String, dynamic> ||
          value['alias'] is! String ||
          value['target'] is! String ||
          value['nonce'] is! String ||
          _pathKey(p.normalize(p.absolute(value['alias'] as String))) !=
              _pathKey(alias)) {
        return null;
      }
      return (
        target: p.normalize(p.absolute(value['target'] as String)),
        nonce: value['nonce'] as String,
      );
    } on Object {
      return null;
    }
  }

  Future<SwiftPmBinaryArtifactPublication> materializeBinaryArtifact({
    required String source,
    required String destination,
    Duration timeout = const Duration(minutes: 2),
    StartBinaryCopy? startProcess,
  }) => _withDestinationLock(
    destination,
    () => _materializeBinaryArtifact(
      source: source,
      destination: destination,
      timeout: timeout,
      startProcess: startProcess ?? _startRobocopy,
    ),
  );

  Future<SwiftPmBinaryArtifactPublication> _materializeBinaryArtifact({
    required String source,
    required String destination,
    required Duration timeout,
    required StartBinaryCopy startProcess,
  }) async {
    await _validateMaterializationSource(source);
    final existing = await _existingMaterialization(source, destination);
    if (existing != null) return existing;

    final parent = Directory(p.dirname(destination));
    await parent.create(recursive: true);
    final temporary = await parent.createTemp('.x-');
    var cleanupTemporary = true;
    try {
      await _copyBinaryArtifact(
        source: source,
        temporary: temporary,
        timeout: timeout,
        startProcess: startProcess,
        retainTemporary: () => cleanupTemporary = false,
      );
      return await _publishMaterialization(
        source: source,
        destination: destination,
        temporary: temporary,
      );
    } finally {
      if (cleanupTemporary && temporary.existsSync()) {
        await temporary.delete(recursive: true);
      }
    }
  }

  Future<void> _validateMaterializationSource(String source) async {
    if (await _completeEntryContaining(source)) return;
    throw FileSystemException(
      'SwiftPM binary artifact source is not a complete store entry',
      source,
    );
  }

  Future<SwiftPmBinaryArtifactPublication?> _existingMaterialization(
    String source,
    String destination,
  ) async {
    if (FileSystemEntity.typeSync(destination, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return null;
    }
    if (await validatesMaterializedBinaryArtifact(
      source: source,
      destination: destination,
    )) {
      return SwiftPmBinaryArtifactPublication.reused;
    }
    throw FileSystemException(
      'SwiftPM binary artifact destination already exists but is not the expected artifact',
      destination,
    );
  }

  static Future<BinaryCopyProcess> _startRobocopy(
    String executable,
    List<String> arguments,
  ) async => _IoBinaryCopyProcess(
    await ProcessRunner.start(
      await ProcessRunner.locateTool(executable),
      arguments,
    ),
  );

  Future<void> _copyBinaryArtifact({
    required String source,
    required Directory temporary,
    required Duration timeout,
    required StartBinaryCopy startProcess,
    required void Function() retainTemporary,
  }) async {
    final process = await startProcess('robocopy', [
      _processPath(source),
      _processPath(temporary.path),
      '/E',
      '/R:0',
      '/W:0',
      '/MT:8',
      '/NFL',
      '/NDL',
      '/NJH',
      '/NJS',
      '/NP',
    ]);
    final output = _DiagnosticCollector(process.stdout);
    final error = _DiagnosticCollector(process.stderr);
    final exitCode = await _awaitCopyProcess(
      process: process,
      output: output,
      error: error,
      source: source,
      temporary: temporary,
      timeout: timeout,
      retainTemporary: retainTemporary,
    );
    if (exitCode > 7) {
      throw FileSystemException(
        'SwiftPM binary artifact copy failed with exit code $exitCode: '
        '${_boundedDiagnostic(error.text, output.text)}',
        source,
      );
    }
    if (!await _sameArtifactTree(source, temporary.path)) {
      throw FileSystemException(
        'SwiftPM binary artifact copy completed with incomplete content',
        temporary.path,
      );
    }
  }

  Future<int> _awaitCopyProcess({
    required BinaryCopyProcess process,
    required _DiagnosticCollector output,
    required _DiagnosticCollector error,
    required String source,
    required Directory temporary,
    required Duration timeout,
    required void Function() retainTemporary,
  }) async {
    final int exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      await _handleCopyTimeout(
        process: process,
        output: output,
        error: error,
        source: source,
        temporary: temporary,
        timeout: timeout,
        retainTemporary: retainTemporary,
      );
      rethrow;
    }
    await output.done;
    await error.done;
    return exitCode;
  }

  Future<void> _handleCopyTimeout({
    required BinaryCopyProcess process,
    required _DiagnosticCollector output,
    required _DiagnosticCollector error,
    required String source,
    required Directory temporary,
    required Duration timeout,
    required void Function() retainTemporary,
  }) async {
    var killed = false;
    const grace = Duration(milliseconds: 100);
    var exitedDuringGrace = false;
    for (var attempt = 0; attempt < 3 && !exitedDuringGrace; attempt++) {
      killed = process.kill() || killed;
      try {
        await process.exitCode.timeout(grace);
        exitedDuringGrace = true;
      } on TimeoutException {
        continue;
      }
    }
    await output.stop();
    await error.stop();
    if (!exitedDuringGrace) {
      retainTemporary();
      await File(
        p.join(temporary.path, '.xcross-live-copy-quarantine'),
      ).writeAsString('retained: process ownership cannot be revalidated');
    }
    throw FileSystemException(
      'SwiftPM binary artifact copy timed out after $timeout; '
      'kill returned $killed; process '
      '${exitedDuringGrace ? 'exited' : 'did not exit'} during $grace grace period: '
      '${_boundedDiagnostic(error.text, output.text)}',
      source,
    );
  }

  Future<SwiftPmBinaryArtifactPublication> _publishMaterialization({
    required String source,
    required String destination,
    required Directory temporary,
  }) async {
    try {
      final publication = SwiftPmBinaryArtifactPublication.published();
      await temporary.rename(destination);
      await _writeMaterializationMarker(
        destination,
        source,
        publication.nonce!,
      );
      return publication;
    } on FileSystemException {
      if (!await validatesMaterializedBinaryArtifact(
        source: source,
        destination: destination,
      )) {
        rethrow;
      }
      return SwiftPmBinaryArtifactPublication.reused;
    }
  }

  Future<bool> validatesBinaryArtifactDestination({
    required String source,
    required String destination,
    required bool alias,
  }) async {
    if (!await _completeEntryContaining(source)) return false;
    if (!alias) return _sameArtifactTree(source, destination);
    final absoluteDestination = p.normalize(p.absolute(destination));
    final marker = File(_aliasMarkerPath(absoluteDestination));
    final ownership = await _managedAliasTarget(absoluteDestination, marker);
    return ownership != null &&
        _pathKey(ownership.target) ==
            _pathKey(p.normalize(p.absolute(source))) &&
        await _isAliasTo(absoluteDestination, ownership.target);
  }

  Future<bool> validatesMaterializedBinaryArtifact({
    required String source,
    required String destination,
  }) => validatesBinaryArtifactDestination(
    source: source,
    destination: destination,
    alias: false,
  );

  Future<void> removeMaterializedBinaryArtifact({
    required String source,
    required String destination,
    required SwiftPmBinaryArtifactPublication publication,
  }) => _withDestinationLock(destination, () async {
    final nonce = publication.nonce;
    if (nonce == null) return;
    final marker = File('$destination.xcross-materialization.json');
    final ownership = await _materializationOwnership(marker);
    if (ownership == null ||
        ownership.nonce != nonce ||
        _pathKey(ownership.destination) !=
            _pathKey(p.normalize(p.absolute(destination))) ||
        _pathKey(ownership.source) !=
            _pathKey(p.normalize(p.absolute(source))) ||
        !await _sameArtifactTree(source, destination)) {
      return;
    }
    final revalidated = await _materializationOwnership(marker);
    if (revalidated == null ||
        revalidated.nonce != nonce ||
        !await _sameArtifactTree(source, destination)) {
      return;
    }
    await Directory(destination).delete(recursive: true);
    if (marker.existsSync()) await marker.delete();
  });

  Future<void> _writeMaterializationMarker(
    String destination,
    String source,
    String nonce,
  ) async {
    final marker = File('$destination.xcross-materialization.json');
    await marker.writeAsString(
      jsonEncode({
        'destination': p.normalize(p.absolute(destination)),
        'source': p.normalize(p.absolute(source)),
        'nonce': nonce,
      }),
      flush: true,
    );
  }

  Future<({String destination, String source, String nonce})?>
  _materializationOwnership(File marker) async {
    try {
      final value = jsonDecode(await marker.readAsString());
      if (value is! Map<String, dynamic> ||
          value['destination'] is! String ||
          value['source'] is! String ||
          value['nonce'] is! String) {
        return null;
      }
      return (
        destination: p.normalize(p.absolute(value['destination'] as String)),
        source: p.normalize(p.absolute(value['source'] as String)),
        nonce: value['nonce'] as String,
      );
    } on Object {
      return null;
    }
  }

  Future<bool> _sameArtifactTree(String source, String destination) async {
    if (FileSystemEntity.typeSync(source, followLinks: false) !=
            FileSystemEntityType.directory ||
        FileSystemEntity.typeSync(destination, followLinks: false) !=
            FileSystemEntityType.directory) {
      return false;
    }
    final sourcePath = _ioPath(source);
    final destinationPath = _ioPath(destination);
    final sourceRoot = Directory(sourcePath);
    final destinationRoot = Directory(destinationPath);
    final sourceEntities = sourceRoot.listSync(
      recursive: true,
      followLinks: false,
    );
    final destinationEntities = destinationRoot.listSync(
      recursive: true,
      followLinks: false,
    );
    if (sourceEntities.length != destinationEntities.length) return false;
    final destinationByPath = {
      for (final entity in destinationEntities)
        _pathKey(p.relative(entity.path, from: destinationPath)): entity,
    };
    for (final entity in sourceEntities) {
      final relative = _pathKey(p.relative(entity.path, from: sourcePath));

      final other = destinationByPath[relative];
      final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
      if (other == null ||
          type != FileSystemEntity.typeSync(other.path, followLinks: false)) {
        return false;
      }
      if (type == FileSystemEntityType.file &&
          !_sameBytes(
            await File(entity.path).readAsBytes(),
            await File(other.path).readAsBytes(),
          )) {
        return false;
      }
    }
    return true;
  }

  static String _processPath(String path) {
    if (!Platform.isWindows) return path;
    final normalized = p.windows.normalize(p.windows.absolute(path));
    if (normalized.startsWith(r'\\?\UNC\')) {
      return r'\\' + normalized.substring(8);
    }
    if (normalized.startsWith(r'\\?\')) return normalized.substring(4);
    return normalized;
  }

  static String _ioPath(String path) {
    if (!Platform.isWindows) return path;
    final absolute = p.windows.normalize(p.windows.absolute(path));
    if (absolute.startsWith(r'\\?\')) return absolute;
    if (absolute.startsWith(r'\\')) {
      return '${r'\\?\UNC\'}${absolute.substring(2)}';
    }
    return '${r'\\?\'}$absolute';
  }

  static bool _sameBytes(List<int> first, List<int> second) {
    if (first.length != second.length) return false;
    for (var index = 0; index < first.length; index++) {
      if (first[index] != second[index]) return false;
    }
    return true;
  }

  Future<bool> _completeEntryContaining(String target) async {
    final root = p.normalize(p.absolute(_store.root));
    final absoluteTarget = p.normalize(p.absolute(target));
    if (!p.isWithin(root, absoluteTarget)) return false;
    var current = Directory(absoluteTarget);
    while (p.isWithin(root, current.path)) {
      final metadata = File(p.join(current.path, 'metadata.json'));
      if (File(p.join(current.path, '.complete')).existsSync() &&
          metadata.existsSync()) {
        try {
          final decoded = jsonDecode(await metadata.readAsString());
          if (decoded is Map<String, dynamic> &&
              decoded['archiveChecksum'] is String &&
              decoded['targetName'] is String) {
            final entry = await _store.findCompleteTarget(
              decoded['archiveChecksum'] as String,
              decoded['targetName'] as String,
            );
            return entry != null &&
                _pathKey(p.normalize(p.absolute(entry.artifactPath))) ==
                    _pathKey(absoluteTarget);
          }
        } on FormatException {
          return false;
        } on FileSystemException {
          return false;
        }
      }
      current = current.parent;
    }
    return false;
  }

  static String _pathKey(String path) =>
      Platform.isWindows ? path.toLowerCase() : path;

  static Future<T> _withDestinationLock<T>(
    String destination,
    Future<T> Function() action,
  ) async {
    final key = _pathKey(p.normalize(p.absolute(destination)));
    final previous = _destinationTails[key];
    final done = Completer<void>();
    _destinationTails[key] = done.future;
    if (previous != null) await previous;
    final file = File('$key.xcross-publication.lock');
    await file.parent.create(recursive: true);
    final lock = await file.open(mode: FileMode.append);
    try {
      await lock.lock();
      return await action();
    } finally {
      await lock.unlock();
      await lock.close();
      done.complete();
      if (identical(_destinationTails[key], done.future)) {
        await _destinationTails.remove(key);
      }
    }
  }

  static String _boundedDiagnostic(String primary, [String secondary = '']) {
    const limit = 1024;
    String clip(String value) =>
        value.length <= limit ? value : '${value.substring(0, limit)}…';
    return [
      clip(primary),
      clip(secondary),
    ].where((value) => value.isNotEmpty).join('\n');
  }

  Future<SwiftPmPreparedBinaryArtifact> prepare(
    SwiftPmRemoteBinaryTarget target,
  ) async {
    final existing = await _store.findCompleteTarget(
      target.checksum,
      target.name,
    );
    if (existing != null) {
      return SwiftPmPreparedBinaryArtifact(target: target, entry: existing);
    }

    File archive;
    final cached = File(_store.archivePath(target.checksum));
    if (cached.existsSync()) {
      archive = await _store.publishArchive(
        cached,
        target.checksum,
        maximumBytes: _maxArchiveBytes,
      );
    } else {
      final stagingParent = Directory(p.join(_store.root, '.staging'));
      await stagingParent.create(recursive: true);
      final staging = await stagingParent.createTemp('download-');
      final downloaded = File(p.join(staging.path, 'archive.zip'));
      try {
        try {
          await _download(target.url, downloaded, _maxArchiveBytes);
        } on FlutterBuildError {
          rethrow;
        } on Object {
          throw FlutterBuildError(
            'Failed to download SwiftPM binary artifact from '
            '${_redactedUrl(target.url)}',
          );
        }
        archive = await _store.publishArchive(
          downloaded,
          target.checksum,
          maximumBytes: _maxArchiveBytes,
        );
      } finally {
        if (staging.existsSync()) await staging.delete(recursive: true);
      }
    }

    final entry = await prepareDownloadedArchive(
      target: target,
      archive: archive,
    );
    return SwiftPmPreparedBinaryArtifact(target: target, entry: entry);
  }

  Future<SwiftPmBinaryArtifactEntry> prepareDownloadedArchive({
    required SwiftPmRemoteBinaryTarget target,
    required File archive,
  }) async {
    final existing = await _store.findCompleteTarget(
      target.checksum,
      target.name,
    );
    if (existing != null) return existing;

    await _store.publishArchive(
      archive,
      target.checksum,
      maximumBytes: _maxArchiveBytes,
    );
    final bytes = Uint8List.fromList(
      await _store.readVerifiedArchiveBytes(
        target.checksum,
        maximumBytes: _maxArchiveBytes,
      ),
    );
    final decoded = _decode(bytes);
    final inspected = _inspect(decoded, target);
    final stagingParent = Directory(p.join(_store.root, '.staging'));
    await stagingParent.create(recursive: true);
    final staging = await stagingParent.createTemp('extract-');
    try {
      final artifact = Directory(
        p.join(staging.path, inspected.artifactDirectoryName),
      );
      await artifact.create(recursive: true);
      try {
        await _extractSelected(inspected, artifact);
      } on FlutterBuildError {
        rethrow;
      } on Object {
        throw FlutterBuildError(
          'SwiftPM binary artifact selected content could not be decompressed',
        );
      }
      _validateDeclaredPaths(inspected.library, artifact);
      return await _store.publishTarget(
        checksum: target.checksum,
        targetName: target.name,
        stagingRoot: staging,
        artifactDirectoryName: inspected.artifactDirectoryName,
        metadata: {
          'formatVersion': 1,
          'libraryIdentifier': inspected.library.identifier,
        },
      );
    } finally {
      if (staging.existsSync()) await staging.delete(recursive: true);
    }
  }

  Archive _decode(Uint8List bytes) {
    try {
      _rejectRawDuplicateEntries(bytes);
      return ZipDecoder().decodeBytes(bytes);
    } on FlutterBuildError {
      rethrow;
    } on Object {
      throw FlutterBuildError('SwiftPM binary artifact is not a valid ZIP');
    }
  }

  static void _rejectRawDuplicateEntries(Uint8List bytes) {
    final eocdStart = bytes.length - 22;
    final eocdLimit = bytes.length > 65557 ? bytes.length - 65557 : 0;
    var eocd = -1;
    for (var offset = eocdStart; offset >= eocdLimit; offset--) {
      if (_uint32(bytes, offset) == 0x06054b50) {
        eocd = offset;
        break;
      }
    }
    if (eocd < 0 || eocd + 22 + _uint16(bytes, eocd + 20) != bytes.length) {
      throw FlutterBuildError('SwiftPM binary artifact is not a valid ZIP');
    }
    final count = _uint16(bytes, eocd + 10);
    final centralSize = _uint32(bytes, eocd + 12);
    final centralOffset = _uint32(bytes, eocd + 16);
    if (count == 0xffff ||
        centralSize == 0xffffffff ||
        centralOffset == 0xffffffff ||
        centralOffset + centralSize != eocd) {
      throw FlutterBuildError(
        'SwiftPM binary artifact uses unsupported ZIP metadata',
      );
    }

    final names = <String>{};
    var offset = centralOffset;
    for (var index = 0; index < count; index++) {
      if (offset + 46 > eocd || _uint32(bytes, offset) != 0x02014b50) {
        throw FlutterBuildError('SwiftPM binary artifact is not a valid ZIP');
      }
      final nameLength = _uint16(bytes, offset + 28);
      final extraLength = _uint16(bytes, offset + 30);
      final commentLength = _uint16(bytes, offset + 32);
      final end = offset + 46 + nameLength + extraLength + commentLength;
      if (end > eocd) {
        throw FlutterBuildError('SwiftPM binary artifact is not a valid ZIP');
      }
      final name = utf8.decode(
        bytes.sublist(offset + 46, offset + 46 + nameLength),
      );
      if (!names.add(name)) {
        throw FlutterBuildError(
          'SwiftPM binary artifact has duplicate ZIP path: $name',
        );
      }
      offset = end;
    }
    if (offset != eocd) {
      throw FlutterBuildError('SwiftPM binary artifact is not a valid ZIP');
    }
  }

  static int _uint16(List<int> bytes, int offset) =>
      bytes[offset] | (bytes[offset + 1] << 8);

  static int _uint32(List<int> bytes, int offset) =>
      _uint16(bytes, offset) | (_uint16(bytes, offset + 2) << 16);

  _InspectedXcFrameworkArchive _inspect(
    Archive archive,
    SwiftPmRemoteBinaryTarget target,
  ) {
    if (archive.files.length > _maxEntries) {
      throw FlutterBuildError(
        'SwiftPM binary artifact exceeds ZIP entry limit',
      );
    }

    var expandedBytes = 0;
    final names = <String>{};
    final foldedNames = <String, String>{};
    final entries = <_ValidatedArchiveEntry>[];
    for (final entry in archive.files) {
      expandedBytes += entry.size;
      if (expandedBytes > _maxExpandedBytes) {
        throw FlutterBuildError(
          'SwiftPM binary artifact exceeds ZIP expanded byte limit',
        );
      }
      final name = _safeArchiveName(entry.name);
      if (!names.add(name)) {
        throw FlutterBuildError(
          'SwiftPM binary artifact has duplicate ZIP path: $name',
        );
      }
      final folded = name.toLowerCase();
      final foldedWinner = foldedNames[folded];
      if (foldedWinner != null && foldedWinner != name) {
        throw FlutterBuildError(
          'SwiftPM binary artifact has case-folded ZIP path collision: '
          '$foldedWinner and $name',
        );
      }
      foldedNames[folded] = name;
      entries.add(_ValidatedArchiveEntry(entry, name));
    }

    final plistName = '${target.name}.xcframework/Info.plist';
    final plistEntries = entries.where((entry) => entry.name == plistName);
    if (plistEntries.length != 1 ||
        !plistEntries.single.file.isFile ||
        plistEntries.single.file.isSymbolicLink) {
      throw FlutterBuildError(
        'SwiftPM binary artifact must contain exactly one root plist for '
        '${target.name}.xcframework',
      );
    }
    final plistBytes = _materialize(
      plistEntries.single.file,
      remainingBytes: _maxExpandedBytes,
    );
    final plist = _decodePlist(plistBytes);
    final materializedBytes = plistBytes.length;
    final librariesValue = plist['AvailableLibraries'];
    if (librariesValue is! List) {
      throw FlutterBuildError(
        'SwiftPM XCFramework AvailableLibraries must be an array',
      );
    }
    final libraries = <_XcFrameworkLibrary>[];
    for (final value in librariesValue) {
      libraries.add(_parseLibrary(value));
    }
    final eligible = libraries
        .where(
          (library) =>
              library.platform == 'ios' &&
              library.variant == null &&
              library.architectures.contains('arm64'),
        )
        .toList();
    if (eligible.length != 1) {
      throw FlutterBuildError(
        'SwiftPM XCFramework must contain exactly one eligible arm64 iOS '
        'device library; found ${eligible.length}',
      );
    }
    final library = eligible.single;
    final selectedPrefix = '${target.name}.xcframework/${library.identifier}/';
    if (entries.any(
      (entry) =>
          entry.name.startsWith(selectedPrefix) && entry.file.isSymbolicLink,
    )) {
      throw FlutterBuildError(
        'Unsupported SwiftPM binary artifact: selected device slice requires '
        'symlinks',
      );
    }
    return _InspectedXcFrameworkArchive(
      entries: entries,
      plist: plist,
      library: library,
      artifactDirectoryName: '${target.name}.xcframework',
      selectedPrefix: selectedPrefix,
      materializedBytes: materializedBytes,
    );
  }

  Future<void> _extractSelected(
    _InspectedXcFrameworkArchive inspected,
    Directory artifact,
  ) async {
    final reducedPlist = <Object?, Object?>{
      ...inspected.plist,
      'AvailableLibraries': [inspected.library.raw],
    };
    await File(p.join(artifact.path, 'Info.plist')).writeAsString(
      PropertyListSerialization.stringWithPropertyList(reducedPlist),
      flush: true,
    );
    var materializedBytes = inspected.materializedBytes;
    for (final entry in inspected.entries) {
      if (!entry.name.startsWith(inspected.selectedPrefix)) continue;
      final relative = entry.name.substring(
        inspected.artifactDirectoryName.length + 1,
      );
      final destination = p.joinAll([artifact.path, ...p.url.split(relative)]);
      if (entry.file.isDirectory) {
        await Directory(destination).create(recursive: true);
      } else {
        await Directory(p.dirname(destination)).create(recursive: true);
        final bytes = _materialize(
          entry.file,
          remainingBytes: _maxExpandedBytes - materializedBytes,
        );
        materializedBytes += bytes.length;
        await File(destination).writeAsBytes(bytes, flush: true);
      }
    }
  }

  void _validateDeclaredPaths(_XcFrameworkLibrary library, Directory artifact) {
    for (final declared in {
      'LibraryPath': library.libraryPath,
      if (library.headersPath != null) 'HeadersPath': library.headersPath!,
      if (library.debugSymbolsPath != null)
        'DebugSymbolsPath': library.debugSymbolsPath!,
    }.entries) {
      final relative = '${library.identifier}/${declared.value}';
      final path = p.joinAll([artifact.path, ...p.url.split(relative)]);
      if (FileSystemEntity.typeSync(path, followLinks: false) ==
          FileSystemEntityType.notFound) {
        throw FlutterBuildError(
          'SwiftPM XCFramework declared ${declared.key} does not exist: '
          '${declared.value}',
        );
      }
    }
  }

  static Uint8List _materialize(
    ArchiveFile entry, {
    required int remainingBytes,
  }) {
    try {
      final bytes = entry.content;
      if (bytes.length > remainingBytes) {
        throw FlutterBuildError(
          'SwiftPM binary artifact exceeds ZIP expanded byte limit',
        );
      }
      return bytes;
    } on FlutterBuildError {
      rethrow;
    } on Object {
      throw FlutterBuildError(
        'SwiftPM binary artifact content could not be decompressed',
      );
    }
  }

  static Map<Object?, Object?> _decodePlist(Uint8List bytes) {
    final Object? value;
    try {
      value = PropertyListSerialization.propertyListWithString(
        utf8.decode(bytes),
      );
    } on Object {
      throw FlutterBuildError('SwiftPM XCFramework Info.plist is malformed');
    }
    if (value is! Map) {
      throw FlutterBuildError(
        'SwiftPM XCFramework Info.plist root must be a dictionary',
      );
    }
    return Map<Object?, Object?>.from(value);
  }

  static _XcFrameworkLibrary _parseLibrary(Object? value) {
    if (value is! Map) {
      throw FlutterBuildError(
        'SwiftPM XCFramework library metadata must be a dictionary',
      );
    }
    final raw = Map<Object?, Object?>.from(value);
    final identifier = _requiredString(raw, 'LibraryIdentifier');
    final libraryPath = _requiredRelativePath(raw, 'LibraryPath');
    final platform = _requiredString(raw, 'SupportedPlatform');
    final variant = raw['SupportedPlatformVariant'];
    if (variant != null && variant is! String) {
      throw FlutterBuildError(
        'SwiftPM XCFramework SupportedPlatformVariant must be a string',
      );
    }
    final architecturesValue = raw['SupportedArchitectures'];
    if (architecturesValue is! List ||
        architecturesValue.any((value) => value is! String)) {
      throw FlutterBuildError(
        'SwiftPM XCFramework SupportedArchitectures must be a string array',
      );
    }
    return _XcFrameworkLibrary(
      raw: raw,
      identifier: _safeRelativePath(identifier, 'LibraryIdentifier'),
      libraryPath: libraryPath,
      headersPath: _optionalRelativePath(raw, 'HeadersPath'),
      debugSymbolsPath: _optionalRelativePath(raw, 'DebugSymbolsPath'),
      platform: platform,
      variant: variant as String?,
      architectures: architecturesValue.cast<String>(),
    );
  }

  static String _requiredString(Map<Object?, Object?> map, String key) {
    final value = map[key];
    if (value is! String || value.isEmpty) {
      throw FlutterBuildError('SwiftPM XCFramework $key must be a string');
    }
    return value;
  }

  static String _requiredRelativePath(Map<Object?, Object?> map, String key) =>
      _safeRelativePath(_requiredString(map, key), key);

  static String? _optionalRelativePath(Map<Object?, Object?> map, String key) {
    final value = map[key];
    if (value == null) return null;
    if (value is! String || value.isEmpty) {
      throw FlutterBuildError('SwiftPM XCFramework $key must be a string');
    }
    return _safeRelativePath(value, key);
  }

  static String _safeRelativePath(String value, String label) {
    if (value.contains(r'\') || p.url.isAbsolute(value)) {
      throw FlutterBuildError('SwiftPM XCFramework $label is unsafe');
    }
    for (final component in p.url.split(value)) {
      if (!_isWindowsSafeComponent(component)) {
        throw FlutterBuildError('SwiftPM XCFramework $label is unsafe');
      }
    }
    if (RegExp('^[A-Za-z]:').hasMatch(value)) {
      throw FlutterBuildError('SwiftPM XCFramework $label is unsafe');
    }
    final normalized = p.url.normalize(value);
    if (normalized == '.' ||
        normalized == '..' ||
        normalized.startsWith('../') ||
        normalized != value) {
      throw FlutterBuildError('SwiftPM XCFramework $label is unsafe');
    }
    return normalized;
  }

  static String _safeArchiveName(String value) {
    if (value.isEmpty || value.contains(r'\') || value.startsWith('/')) {
      throw FlutterBuildError('SwiftPM binary artifact has unsafe ZIP path');
    }
    final withoutTrailingSlash = value.endsWith('/')
        ? value.substring(0, value.length - 1)
        : value;
    for (final component in p.url.split(withoutTrailingSlash)) {
      if (!_isWindowsSafeComponent(component)) {
        throw FlutterBuildError('SwiftPM binary artifact has unsafe ZIP path');
      }
    }
    if (RegExp('^[A-Za-z]:').hasMatch(value)) {
      throw FlutterBuildError('SwiftPM binary artifact has unsafe ZIP path');
    }
    final normalized = p.url.normalize(withoutTrailingSlash);
    if (normalized == '.' ||
        normalized == '..' ||
        normalized.startsWith('../') ||
        normalized != withoutTrailingSlash) {
      throw FlutterBuildError('SwiftPM binary artifact has unsafe ZIP path');
    }
    return normalized;
  }

  static bool _isWindowsSafeComponent(String value) {
    if (value.isEmpty || value.endsWith('.') || value.endsWith(' ')) {
      return false;
    }
    for (final codeUnit in value.codeUnits) {
      if (codeUnit < 0x20 ||
          codeUnit > 0x7e ||
          r'<>:"/\|?*'.codeUnits.contains(codeUnit)) {
        return false;
      }
    }
    final basename = value.split('.').first.toUpperCase();
    return basename != r'CONIN$' &&
        basename != r'CONOUT$' &&
        basename != r'CLOCK$' &&
        basename != 'CON' &&
        basename != 'PRN' &&
        basename != 'AUX' &&
        basename != 'NUL' &&
        !RegExp(r'^(COM|LPT)[1-9]$').hasMatch(basename);
  }

  static String _redactedUrl(Uri url) {
    final last = url.pathSegments
        .where((segment) => segment.isNotEmpty)
        .lastOrNull;
    final path = last == null ? '' : '/$last';
    return Uri(
      scheme: url.scheme,
      host: url.host,
      port: url.hasPort ? url.port : null,
      path: path,
    ).toString();
  }

  static Future<void> _defaultDownload(
    Uri url,
    File destination,
    int maximumBytes,
  ) async {
    final client = HttpClient();
    IOSink? output;
    try {
      final request = await client.getUrl(url);
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'HTTP ${response.statusCode} while downloading archive',
          uri: url,
        );
      }
      if (response.contentLength > maximumBytes) {
        throw FlutterBuildError(_archiveByteLimitMessage);
      }
      await destination.parent.create(recursive: true);
      output = destination.openWrite();
      var downloadedBytes = 0;
      await for (final chunk in response) {
        if (downloadedBytes + chunk.length > maximumBytes) {
          throw FlutterBuildError(_archiveByteLimitMessage);
        }
        output.add(chunk);
        downloadedBytes += chunk.length;
      }
      await output.flush();
    } finally {
      client.close(force: true);
      await output?.close();
      if (destination.existsSync() && destination.lengthSync() > maximumBytes) {
        await destination.delete();
      }
    }
  }
}

final class _DiagnosticCollector {
  _DiagnosticCollector(Stream<List<int>> stream) {
    _subscription = stream
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((chunk) {
          if (_buffer.length >= _limit) return;
          final remaining = _limit - _buffer.length;
          _buffer.write(
            chunk.length <= remaining ? chunk : chunk.substring(0, remaining),
          );
        }, onDone: _done.complete);
  }

  static const _limit = 1024;
  final _buffer = StringBuffer();
  final _done = Completer<void>();
  late final StreamSubscription<String> _subscription;

  Future<void> get done => _done.future;
  String get text => _buffer.toString();

  Future<void> stop() async {
    await _subscription.cancel();
    if (!_done.isCompleted) _done.complete();
  }
}

final class _ValidatedArchiveEntry {
  const _ValidatedArchiveEntry(this.file, this.name);

  final ArchiveFile file;
  final String name;
}

final class _XcFrameworkLibrary {
  const _XcFrameworkLibrary({
    required this.raw,
    required this.identifier,
    required this.libraryPath,
    required this.headersPath,
    required this.debugSymbolsPath,
    required this.platform,
    required this.variant,
    required this.architectures,
  });

  final Map<Object?, Object?> raw;
  final String identifier;
  final String libraryPath;
  final String? headersPath;
  final String? debugSymbolsPath;
  final String platform;
  final String? variant;
  final List<String> architectures;
}

final class _InspectedXcFrameworkArchive {
  const _InspectedXcFrameworkArchive({
    required this.entries,
    required this.plist,
    required this.library,
    required this.artifactDirectoryName,
    required this.selectedPrefix,
    required this.materializedBytes,
  });

  final List<_ValidatedArchiveEntry> entries;
  final Map<Object?, Object?> plist;
  final _XcFrameworkLibrary library;
  final String artifactDirectoryName;
  final String selectedPrefix;
  final int materializedBytes;
}
