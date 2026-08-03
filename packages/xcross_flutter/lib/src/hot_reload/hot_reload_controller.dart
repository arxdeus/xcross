import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:xcross_flutter/src/constants.dart';
import 'package:xcross_flutter/src/hot_reload/dart_vm_service_client.dart';
import 'package:xcross_flutter/src/hot_reload/frontend_server_client.dart';
import 'package:xcross_flutter/src/hot_reload/source_watcher.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:xcross_flutter/src/models/hot_reload_config.dart';
import 'package:xcross_flutter/src/errors.dart';

/// Drives Flutter hot reload / hot restart by:
///   1. Spawning a persistent `frontend_server` for incremental kernel diffs.
///   2. Uploading those diffs into the app's devFS over HTTP.
///   3. Calling `reloadSources` / `_flutter.runInView` on the Dart VM Service.
class HotReloadController {
  HotReloadController({
    required this.config,
    required this.vm,
    required DeviceEndpoint vmService,
  }) : _httpBase =
           'http://${ProcessRunner.bracketHost(vmService.host)}:'
           '${vmService.port}/',
       _frontend = FrontendServerClient(config),
       _sources = SourceWatcher(config);

  /// Fallback devFS base URI used when `_createDevFs` does not return one.
  static const _devFsFallbackUri =
      'org-dartlang-devfs://${FlutterDeviceConstants.devFsName}/';

  final HotReloadConfig config;
  final DartVmServiceClient vm;
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
    await _registerExpressionCompiler();
  }

  /// Serve the VM Service `compileExpression` service from our frontend_server.
  ///
  /// The Flutter engine embeds no kernel compiler, so the VM delegates
  /// expression compilation to a registered client. With nobody registered
  /// every `evaluate` fails — which is also how DevTools decides an app is a
  /// profile build (it probes with `Platform.isAndroid`), disabling the Flutter
  /// Inspector and Debugger screens on a perfectly good debug build.
  ///
  /// Best effort: reload still works without it.
  Future<void> _registerExpressionCompiler() async {
    try {
      await vm.registerService('compileExpression', 'xcross', (params) async {
        final kernel = await _frontend.compileExpression(
          expression: params['expression'] as String? ?? '',
          definitions: _stringList(params['definitions']),
          definitionTypes: _stringList(params['definitionTypes']),
          typeDefinitions: _stringList(params['typeDefinitions']),
          typeBounds: _stringList(params['typeBounds']),
          typeDefaults: _stringList(params['typeDefaults']),
          libraryUri: params['libraryUri'] as String? ?? '',
          klass: params['klass'] as String?,
          method: params['method'] as String?,
          isStatic: params['isStatic'] == true,
        );
        // Shape mirrors flutter_tools' handler exactly; the VM reads
        // `result.kernelBytes`.
        return {
          'type': 'Success',
          'result': {'kernelBytes': base64Encode(kernel)},
        };
      });
    } on Object catch (e) {
      Log.logWarn('expression evaluation unavailable: $e');
    }
  }

  /// Tolerates a missing or differently-typed list: the parameter set has grown
  /// over VM versions (`typeDefaults` is recent), and an absent one is empty,
  /// not an error.
  static List<String> _stringList(Object? value) => switch (value) {
    final List<Object?> list => list.whereType<String>().toList(),
    _ => const [],
  };

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
      Log.logTrace('[timing] $label ${sw.elapsedMilliseconds}ms');
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
      // The step's own `✓ Reloaded 0.0s` already tells the story.
      Log.logTrace('no source changes');
      return true;
    }

    final dill = await _timed(
      'recompile',
      () => _frontend.recompile(invalidated: changed),
    );
    final targetUri = await _timed('devfs-upload', () => _uploadDill(dill));

    final isolateId = await _rootIsolateIdCached();
    if (isolateId == null) throw FlutterBuildError('no Flutter isolate to reload');

    final ok = await _timed('reloadSources', () async {
      final report = await vm.call(
        'reloadSources',
        params: {
          'isolateId': isolateId,
          'force': false,
          'rootLibUri': targetUri,
        },
      );
      return report['success'] == true;
    });
    if (ok) {
      await _frontend.accept();
      await _timed('reassemble', () async {
        try {
          await vm.call(
            'ext.flutter.reassemble',
            params: {'isolateId': isolateId},
          );
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
    final changed = _sources.changedFileUris();
    _cachedRootIsolate = null; // a new isolate comes up after runInView
    // MUST reset before recompiling: without it frontend_server emits an
    // incremental delta (to `<output-dill>.incremental.dill`), and runInView
    // cannot boot an isolate from a partial program — it just never becomes
    // runnable, which reads as a dead hang.
    await _frontend.reset();
    final dill = await _timed(
      'restart-recompile',
      () => _frontend.recompile(invalidated: changed),
    );
    // Alternate the devFS file name so runInView always loads a fresh URI —
    // runInView will not reload an identical URI, so a stable filename makes
    // every second hot restart a silent no-op that still reports success.
    _restartCount++;
    final fileName = _restartCount.isEven
        ? 'main.dart.dill'
        : 'main.dart.swap.dill';
    final targetUri = await _timed(
      'restart-devfs-upload',
      () => _uploadDill(dill, fileName: fileName),
    );
    await _frontend.accept();

    await vm.streamListen('Isolate');
    final viewIds = await _flutterViewIds();
    final assetDir = '${_devFsBaseUri ?? _devFsFallbackUri}flutter_assets/';
    const longTimeout = Duration(minutes: 2);
    for (final viewId in viewIds) {
      // ORDER MATTERS: `events` is a broadcast stream, so the subscription must
      // exist before runInView fires or the event is missed.
      final runnable = vm.waitForEvent('IsolateRunnable', timeout: longTimeout);
      await _timed(
        'runInView',
        () => vm.call(
          '_flutter.runInView',
          params: {
            'viewId': viewId,
            'mainScript': targetUri,
            'assetDirectory': assetDir,
          },
          timeout: longTimeout,
        ),
      );
      // waitForEvent swallows its timeout and yields {} — surface that instead
      // of reporting a restart that never happened.
      if ((await _timed('await-IsolateRunnable', () => runnable)).isEmpty) {
        throw FlutterBuildError(
          'isolate never became runnable after runInView (${longTimeout.inMinutes}m)',
        );
      }
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
        vm.call('_createDevFS', params: {'fsName': FlutterDeviceConstants.devFsName});

    Map<String, dynamic> data;
    try {
      data = await tryCreate();
    } catch (e) {
      if (e.toString().contains('already exists')) {
        try {
          await vm.call(
            '_deleteDevFS',
            params: {'fsName': FlutterDeviceConstants.devFsName},
          );
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
  Future<String> _uploadDill(
    String dillPath, {
    String fileName = 'main.dart.dill',
  }) async {
    final baseUri = _devFsBaseUri ?? _devFsFallbackUri;
    final targetUri = '$baseUri$fileName';
    final raw = await File(dillPath).readAsBytes();
    final gz = GZipCodec().encode(raw);
    Log.logTrace('[timing] devfs-bytes raw=${raw.length} gz=${gz.length}');
    final targetUriB64 = base64.encode(utf8.encode(targetUri));

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.putUrl(Uri.parse(_httpBase));
      req.headers.set('dev_fs_name', FlutterDeviceConstants.devFsName);
      req.headers.set('dev_fs_uri_b64', targetUriB64);
      req.headers.contentType = ContentType('application', 'octet-stream');
      req.contentLength = gz.length;
      req.add(gz);
      // Bound the PUT: without this a stalled devFS handler on the device hangs
      // the whole session with no output.
      final resp = await req.close().timeout(const Duration(seconds: 120));
      await resp.drain<void>().timeout(const Duration(seconds: 30));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw FlutterBuildError('devFS upload failed: HTTP ${resp.statusCode}');
      }
    } catch (e) {
      if (e is FlutterBuildError) rethrow;
      throw FlutterBuildError('devFS upload failed: $e');
    } finally {
      client.close();
    }
    return targetUri;
  }
}
