import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:xcross/src/config/config.dart';
import 'package:xcross/src/config/runtime_config.dart';
import 'package:xcross/src/errors.dart';

typedef SetupScriptDownload = Future<List<int>> Function(Uri uri);
typedef SetupScriptExecute =
    Future<void> Function(String executable, List<String> arguments);

final class SetupScriptManager {
  static const _downloadTimeout = Duration(seconds: 30);
  static final _contentHashPattern = RegExp(r'^[0-9a-f]{64}$');

  SetupScriptManager({
    String? source,
    Map<String, String>? environment,
    bool? windows,
    SetupScriptDownload? download,
    SetupScriptExecute? execute,
  }) : source = source ?? _configuredSource(),
       environment = environment ?? Platform.environment,
       windows = windows ?? Platform.isWindows,
       _download = download ?? _downloadBytes,
       _execute = execute ?? _executeScript;

  final String? source;
  final Map<String, String> environment;
  final bool windows;
  final SetupScriptDownload _download;
  final SetupScriptExecute _execute;

  bool get isConfigured => source != null;
  bool get isRemote => source != null && _remoteUri(source!) != null;

  Future<File?> resolve() async {
    final configuredSource = source;
    if (configuredSource == null) return null;

    final uri = _remoteUri(configuredSource);
    if (uri == null) return File(configuredSource);

    return _cachedScript(uri) ?? refresh();
  }

  Future<File?> refresh() async {
    final configuredSource = source;
    if (configuredSource == null) return null;

    final uri = _remoteUri(configuredSource);
    if (uri == null) return File(configuredSource);

    final contents = await _download(uri);
    if (contents.isEmpty) {
      throw XcrossError('Configured setup script is empty: $uri');
    }

    final contentHash = sha256.convert(contents).toString();
    final cachedScript = _cachedFile(contentHash);
    cachedScript.parent.createSync(recursive: true);
    if (!_hasDigest(cachedScript, contentHash)) {
      _writeBytesAtomically(cachedScript, contents);
    }
    _writeStringAtomically(_cachePointer(uri), contentHash);
    return cachedScript;
  }

  Future<void> run() async {
    final script = await resolve();
    if (script == null) return;
    if (!script.existsSync()) {
      throw XcrossError(
        'Configured setup script does not exist: ${script.path}',
      );
    }

    final invocation = await _invocation(script.path);
    await _execute(invocation.executable, invocation.arguments);
  }

  String get _cacheDirectory {
    if (windows) {
      final base = environment['LOCALAPPDATA'] ?? environment['APPDATA'];
      if (base == null) {
        throw XcrossError('LOCALAPPDATA is required to cache setup scripts.');
      }
      return p.windows.join(base, 'xcross', 'cache', 'setup-scripts');
    }

    final xdgCache = environment['XDG_CACHE_HOME'];
    if (xdgCache != null) {
      return p.posix.join(xdgCache, 'xcross', 'setup-scripts');
    }
    final home = environment['HOME'];
    if (home == null) {
      throw XcrossError('HOME is required to cache setup scripts.');
    }
    return p.posix.join(home, '.cache', 'xcross', 'setup-scripts');
  }

  File? _cachedScript(Uri uri) {
    final pointer = _cachePointer(uri);
    if (!pointer.existsSync()) return null;

    try {
      final contentHash = pointer.readAsStringSync().trim();
      if (!_contentHashPattern.hasMatch(contentHash)) return null;

      final script = _cachedFile(contentHash);
      return _hasDigest(script, contentHash) ? script : null;
    } on FileSystemException {
      return null;
    }
  }

  File _cachedFile(String contentHash) =>
      File(p.join(_cacheDirectory, '$contentHash${windows ? '.ps1' : '.sh'}'));

  bool _hasDigest(File file, String expected) {
    if (!file.existsSync()) return false;
    try {
      return sha256.convert(file.readAsBytesSync()).toString() == expected;
    } on FileSystemException {
      return false;
    }
  }

  void _writeBytesAtomically(File destination, List<int> contents) {
    final temporary = _temporaryFile(destination);
    try {
      temporary.writeAsBytesSync(contents, flush: true);
      _replaceAtomically(temporary, destination);
    } finally {
      _deleteTemporaryFile(temporary);
    }
  }

  void _writeStringAtomically(File destination, String contents) {
    final temporary = _temporaryFile(destination);
    try {
      temporary.writeAsStringSync(contents, flush: true);
      _replaceAtomically(temporary, destination);
    } finally {
      _deleteTemporaryFile(temporary);
    }
  }

  void _deleteTemporaryFile(File temporary) {
    try {
      if (temporary.existsSync()) temporary.deleteSync();
    } on FileSystemException {
      return;
    }
  }

  File _temporaryFile(File destination) => File(
    '${destination.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp',
  );

  void _replaceAtomically(File temporary, File destination) {
    try {
      temporary.renameSync(destination.path);
      return;
    } on FileSystemException {
      if (!windows || !destination.existsSync()) rethrow;
    }

    final backup = _temporaryFile(destination);
    destination.renameSync(backup.path);
    try {
      temporary.renameSync(destination.path);
      backup.deleteSync();
    } on FileSystemException {
      if (!destination.existsSync() && backup.existsSync()) {
        backup.renameSync(destination.path);
      }
      rethrow;
    }
  }

  File _cachePointer(Uri uri) {
    final urlHash = sha256.convert(utf8.encode(uri.toString()));
    return File(p.join(_cacheDirectory, '$urlHash.current'));
  }

  Future<({String executable, List<String> arguments})> _invocation(
    String scriptPath,
  ) async {
    if (!windows) {
      return (executable: '/bin/sh', arguments: [scriptPath]);
    }
    return (
      executable: await ProcessRunner.locateTool('powershell'),
      arguments: ['-NoProfile', '-File', scriptPath],
    );
  }

  static String? _configuredSource() => XcrossRuntimeConfig.isInitialized
      ? XcrossRuntimeConfig.current.config?.setup
      : null;

  static Uri? _remoteUri(String value) =>
      XcrossConfig.remoteSetupScriptUri(value);

  static Future<List<int>> _downloadBytes(Uri uri) async {
    try {
      final response = await http.get(uri).timeout(_downloadTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw XcrossError(
          'Failed to download configured setup script: '
          'HTTP ${response.statusCode}',
        );
      }
      return response.bodyBytes;
    } on XcrossError {
      rethrow;
    } on TimeoutException {
      throw XcrossError(
        'Failed to download configured setup script: '
        'request timed out after ${_downloadTimeout.inSeconds} seconds '
        '(${_displayUri(uri)})',
      );
    } on Exception catch (error) {
      throw XcrossError(
        'Failed to download configured setup script from '
        '${_displayUri(uri)}: $error',
      );
    }
  }

  static String _displayUri(Uri uri) {
    final sanitized = Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: uri.path,
    );
    return sanitized.toString();
  }

  static Future<void> _executeScript(
    String executable,
    List<String> arguments,
  ) => ProcessRunner.runChecked(executable, arguments, label: 'setup script');
}
