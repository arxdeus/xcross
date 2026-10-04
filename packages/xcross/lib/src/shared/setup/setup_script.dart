import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:xcross/src/shared/config/config.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/setup/setup_script_policy.dart';

typedef SetupScriptDownload = Future<List<int>> Function(Uri uri);
typedef SetupScriptExecute =
    Future<void> Function(String executable, List<String> arguments);

final class SetupScriptManager {
  static const _downloadTimeout = Duration(seconds: 30);
  static final _contentHashPattern = RegExp(r'^[0-9a-f]{64}$');

  SetupScriptManager({
    required this.host,
    required this.createHttpClient,
    required ProcessRunner runner,
    required SetupScriptPolicy policy,
    this.source,
    SetupScriptDownload? download,
    SetupScriptExecute? execute,
  }) : _policy = policy,
       _download = download ?? ((uri) => _downloadBytes(uri, createHttpClient)),
       _execute =
           execute ??
           ((executable, arguments) =>
               runner.runChecked(executable, arguments, label: 'setup script'));

  final PlatformHostInterface host;
  final http.Client Function() createHttpClient;
  final String? source;
  final SetupScriptPolicy _policy;
  final SetupScriptDownload _download;
  final SetupScriptExecute _execute;

  bool get isConfigured => source != null;
  bool get isRemote => source != null && _remoteUri(source!) != null;

  Future<File?> resolve() async {
    final configuredSource = source;
    if (configuredSource == null) return null;

    final uri = _remoteUri(configuredSource);
    if (uri == null) return host.fileSystem.file(configuredSource);

    return _cachedScript(uri) ?? refresh();
  }

  Future<File?> refresh() async {
    final configuredSource = source;
    if (configuredSource == null) return null;

    final uri = _remoteUri(configuredSource);
    if (uri == null) return host.fileSystem.file(configuredSource);

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

    final invocation = await _policy.invocation(script.path);
    await _execute(invocation.executable, invocation.arguments);
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

  File _cachedFile(String contentHash) => _policy.cachedFile(contentHash);

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
      _policy.replace(temporary, destination);
    } finally {
      _deleteTemporaryFile(temporary);
    }
  }

  void _writeStringAtomically(File destination, String contents) {
    final temporary = _temporaryFile(destination);
    try {
      temporary.writeAsStringSync(contents, flush: true);
      _policy.replace(temporary, destination);
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

  File _temporaryFile(File destination) => host.fileSystem.file(
    '${destination.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp',
  );

  File _cachePointer(Uri uri) => _policy.cachePointer(
    sha256.convert(utf8.encode(uri.toString())).toString(),
  );

  static Uri? _remoteUri(String value) =>
      XcrossConfig.remoteSetupScriptUri(value);

  static Future<List<int>> _downloadBytes(
    Uri uri,
    http.Client Function() createClient,
  ) async {
    http.Client? client;
    try {
      client = createClient();
      final response = await client.get(uri).timeout(_downloadTimeout);
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
    } finally {
      client?.close();
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
}
