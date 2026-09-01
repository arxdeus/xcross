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
    final cachedScript = File(p.join(_cacheDirectory, '$contentHash.sh'));
    cachedScript.parent.createSync(recursive: true);
    if (!cachedScript.existsSync()) {
      cachedScript.writeAsBytesSync(contents, flush: true);
    }
    _cachePointer(uri).writeAsStringSync(contentHash, flush: true);
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

    final contentHash = pointer.readAsStringSync().trim();
    final script = File(p.join(_cacheDirectory, '$contentHash.sh'));
    return script.existsSync() ? script : null;
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
    final response = await http.get(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw XcrossError(
        'Failed to download configured setup script: HTTP ${response.statusCode}',
      );
    }
    return response.bodyBytes;
  }

  static Future<void> _executeScript(
    String executable,
    List<String> arguments,
  ) => ProcessRunner.runChecked(executable, arguments, label: 'setup script');
}
