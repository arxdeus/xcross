import 'dart:convert';
import 'dart:io';

import 'package:xcross/src/constants.dart';
import 'package:xcross/src/device/dart_vm_service_client.dart';
import 'package:xcross/src/device/frontend_server_client.dart';
import 'package:xcross/src/device/source_watcher.dart';
import 'package:xcross/src/models/device/hot_reload_config.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';
import 'package:xcross/src/util/process.dart';

/// Drives Flutter hot reload / hot restart by:
///   1. Spawning a persistent `frontend_server` for incremental kernel diffs.
///   2. Uploading those diffs into the app's devFS over HTTP.
///   3. Calling `reloadSources` / `_flutter.runInView` on the Dart VM Service.
class HotReloadController {
  HotReloadController({
    required this.config,
    required this.vm,
    required this.tunnelAddress,
    required int vmServicePort,
  })  : _httpBase = 'http://${bracketHost(tunnelAddress)}:$vmServicePort/',
        _frontend = FrontendServerClient(config),
        _sources = SourceWatcher(config);

  /// Fallback devFS base URI used when `_createDevFs` does not return one.
  static const _devFsFallbackUri =
      'org-dartlang-devfs://${DeviceConstants.devFsName}/';

  final HotReloadConfig config;
  final DartVmServiceClient vm;
  final String tunnelAddress;
  final String _httpBase;
  final FrontendServerClient _frontend;
  final SourceWatcher _sources;

  String? _devFsBaseUri;

  /// Incremented per hot restart to alternate the devFS dill filename.
  int _restartCount = 0;

  /// Cached root Flutter isolate id so reload doesn't re-`listViews` each time.
  /// Cleared on hot restart (which spins up a new isolate).
  String? _cachedRootIsolate;

  /// Initial compile + devFS creation. Call once after VM Service connects.
  Future<void> initialSync() async {
    await _frontend.spawn();
    await _createDevFs();
    // App already runs its bundled kernel. We only prime frontend_server's
    // incremental state here; uploading the full seed dill makes first reload
    // wait behind a multi-MB devFS transfer.
    await _frontend.compile();
    await _frontend.accept();
    _sources.snapshot();
  }

  Future<void> close() async {
    await _frontend.close();
    // Close the VM Service WebSocket so its socket/timers don't keep the event
    // loop alive after the session ends.
    await vm.close();
  }

  /// Time [body] and log `[timing] <label> <ms>ms` (helps locate reload cost).
  Future<T> _timed<T>(String label, Future<T> Function() body) async {
    if (!config.verbose) return body();
    final sw = Stopwatch()..start();
    try {
      return await body();
    } finally {
      logStatus('[timing] $label ${sw.elapsedMilliseconds}ms');
    }
  }

  /// Recompile changed sources, push delta, reload the ROOT Flutter isolate.
  ///
  /// Only the root isolate is reloaded (via `_flutter.listViews`), like
  /// flutter_tools — reloading every isolate from `getVM` can hit a worker
  /// isolate that rejects, which discarded the whole (good) delta and forced a
  /// redo.
  Future<bool> reload() async {
    final changed = _sources.changedFileUris();
    if (changed.isEmpty) {
      logStatus('[xtool] no source changes');
      return true;
    }

    final dill = await _timed(
        'recompile', () => _frontend.recompile(invalidated: changed));
    final targetUri = await _timed('devfs-upload', () => _uploadDill(dill));

    final isolateId = await _rootIsolateIdCached();
    if (isolateId == null) throw XcrossError('no Flutter isolate to reload');

    final ok = await _timed('reloadSources', () async {
      final report = await vm.call('reloadSources', params: {
        'isolateId': isolateId,
        'force': false,
        'rootLibUri': targetUri,
      });
      return report['success'] == true;
    });
    if (ok) {
      await _frontend.accept();
      await _timed('reassemble', () async {
        try {
          await vm
              .call('ext.flutter.reassemble', params: {'isolateId': isolateId});
        } catch (_) {}
      });
    } else {
      await _frontend.reject();
    }
    return ok;
  }

  /// Full restart: recompile, push (to an alternating swap dill), then
  /// `_flutter.runInView` on each view and await the isolate becoming runnable
  /// (rather than the RPC's own return, which on-device can exceed the default
  /// timeout).
  Future<void> restart() async {
    // Force a full recompile if nothing changed, so runInView gets a dill.
    var changed = _sources.changedFileUris();
    if (changed.isEmpty) {
      changed = [for (final p in _sources.dartFiles()) Uri.file(p).toString()];
    }
    _cachedRootIsolate = null; // a new isolate comes up after runInView
    final dill = await _frontend.recompile(invalidated: changed);
    // Alternate the devFS file name so runInView always loads a fresh URI —
    // runInView will not reload an identical URI, so a stable filename makes
    // every second hot restart a silent no-op that still reports success.
    _restartCount++;
    final fileName =
        _restartCount.isEven ? 'main.dart.dill' : 'main.dart.swap.dill';
    final targetUri = await _uploadDill(dill, fileName: fileName);
    await _frontend.accept();

    await vm.streamListen('Isolate');
    final viewIds = await _flutterViewIds();
    final assetDir = '${_devFsBaseUri ?? _devFsFallbackUri}flutter_assets/';
    const longTimeout = Duration(minutes: 2);
    for (final viewId in viewIds) {
      // ORDER MATTERS: `events` is a broadcast stream, so the subscription must
      // exist before runInView fires or the event is missed.
      final runnable = vm.waitForEvent('IsolateRunnable', timeout: longTimeout);
      await vm.call(
        '_flutter.runInView',
        params: {
          'viewId': viewId,
          'mainScript': targetUri,
          'assetDirectory': assetDir,
        },
        timeout: longTimeout,
      );
      await runnable;
    }
  }

  /// Cached root isolate id (avoids a `_flutter.listViews` round-trip per reload).
  Future<String?> _rootIsolateIdCached() async =>
      _cachedRootIsolate ??= await _rootIsolateId();

  /// The root Flutter isolate id (first view's isolate) via `_flutter.listViews`.
  Future<String?> _rootIsolateId() async {
    for (final view in await _flutterViews()) {
      if (view case {'isolate': {'id': final String id}}) return id;
    }
    return null;
  }

  Future<List<Map<String, dynamic>>> _flutterViews() async {
    final viewData = await vm.call('_flutter.listViews');
    final viewArray = viewData['views'] as List<dynamic>? ?? [];
    return viewArray.whereType<Map<String, dynamic>>().toList();
  }

  Future<List<String>> _flutterViewIds() async => [
        for (final v in await _flutterViews())
          if (v case {'id': final String id}) id,
      ];

  Future<void> _createDevFs() async {
    Future<Map<String, dynamic>> tryCreate() =>
        vm.call('_createDevFS', params: {'fsName': DeviceConstants.devFsName});

    Map<String, dynamic> data;
    try {
      data = await tryCreate();
    } catch (e) {
      if (e.toString().contains('already exists')) {
        try {
          await vm.call('_deleteDevFS',
              params: {'fsName': DeviceConstants.devFsName});
        } catch (_) {}
        data = await tryCreate();
      } else {
        rethrow;
      }
    }
    _devFsBaseUri = data['uri'] as String? ?? _devFsFallbackUri;
  }

  /// PUT [dillPath] (gzipped) into devFS as [fileName].
  /// Returns the devFS URI of the uploaded file.
  ///
  /// contentLength must stay exact and the body must not be re-encoded or
  /// chunked — the VM Service devFS handler reads exactly contentLength bytes.
  Future<String> _uploadDill(String dillPath,
      {String fileName = 'main.dart.dill'}) async {
    final baseUri = _devFsBaseUri ?? _devFsFallbackUri;
    final targetUri = '$baseUri$fileName';
    final raw = await File(dillPath).readAsBytes();
    final gz = GZipCodec().encode(raw);
    if (config.verbose) {
      logStatus('[timing] devfs-bytes raw=${raw.length} gz=${gz.length}');
    }
    final targetUriB64 = base64.encode(utf8.encode(targetUri));

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.putUrl(Uri.parse(_httpBase));
      req.headers.set('dev_fs_name', DeviceConstants.devFsName);
      req.headers.set('dev_fs_uri_b64', targetUriB64);
      req.headers.contentType = ContentType('application', 'octet-stream');
      req.contentLength = gz.length;
      req.add(gz);
      final resp = await req.close();
      await resp.drain<void>();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw XcrossError('devFS upload failed: HTTP ${resp.statusCode}');
      }
    } catch (e) {
      if (e is XcrossError) rethrow;
      throw XcrossError('devFS upload failed: $e');
    } finally {
      client.close();
    }
    return targetUri;
  }
}
