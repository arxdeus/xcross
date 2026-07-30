import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:xcross/src/util/errors.dart';

/// JSON-RPC 2.0 client for the Dart VM Service over WebSocket.
class DartVmServiceClient {
  DartVmServiceClient();

  WebSocketChannel? _channel;
  int _nextId = 0;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  final Map<int, Timer> _timers = {};
  StreamSubscription<dynamic>? _sub;

  /// Broadcast of VM Service stream events (`streamNotify` — e.g. `Isolate`
  /// `IsolateRunnable`). Callers `streamListen` first, then await here.
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get events => _events.stream;

  /// Handlers for services we registered; the VM calls *into* us for these.
  final Map<String, Future<Map<String, Object?>> Function(Map<String, Object?>)>
      _services = {};

  /// Register a service the VM can call back into, e.g. `compileExpression`.
  ///
  /// [handler] returns the reply body; throwing becomes an error response.
  Future<void> registerService(
    String service,
    String alias,
    Future<Map<String, Object?>> Function(Map<String, Object?> params) handler,
  ) async {
    _services[service] = handler;
    await call('registerService', params: {'service': service, 'alias': alias});
  }

  /// Subscribe to a VM Service event stream (idempotent — ignores
  /// "already subscribed").
  Future<void> streamListen(String streamId) async {
    try {
      await call('streamListen', params: {'streamId': streamId});
    } on XcrossError {
      // Already subscribed / unsupported — fine.
    }
  }

  /// Complete when a `streamNotify` event of [kind] arrives (up to [timeout]).
  ///
  /// Swallows the timeout: a device that never emits the event reports success
  /// after [timeout] rather than throwing. Callers depend on that.
  Future<Map<String, dynamic>> waitForEvent(
    String kind, {
    Duration timeout = const Duration(seconds: 60),
  }) {
    return events
        .firstWhere((e) => e['kind'] == kind)
        .timeout(timeout, onTimeout: () => const {});
  }

  /// Connect to the VM Service WebSocket at [url].
  Future<void> connect(Uri url,
      {Duration timeout = const Duration(seconds: 30)}) async {
    try {
      _channel = WebSocketChannel.connect(url);
      await _channel!.ready.timeout(timeout);
    } catch (e) {
      throw XcrossError('VM Service connect failed: $e');
    }
    _sub = _channel!.stream.listen(
      _onMessage,
      onError: (_) => _handleClose(),
      onDone: _handleClose,
    );
  }

  Future<void> close() async {
    await _channel?.sink.close();
    _handleClose();
  }

  /// Perform a JSON-RPC call; returns the `result` map.
  Future<Map<String, dynamic>> call(
    String method, {
    Map<String, dynamic> params = const {},
    Duration timeout = const Duration(seconds: 30),
  }) {
    final ch = _channel;
    if (ch == null) throw XcrossError('VM Service: not connected');

    final id = ++_nextId;
    final request = jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });

    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    ch.sink.add(request);

    // Arm a timeout — and KEEP the Timer so we can cancel it on reply. A live
    // Timer keeps the Dart event loop alive; leaking one per RPC is why the
    // process wouldn't exit (Ctrl-C hang).
    _timers[id] = Timer(timeout, () {
      _timers.remove(id);
      if (_pending.remove(id) != null && !c.isCompleted) {
        c.completeError(XcrossError('VM Service: $method timed out'));
      }
    });

    return c.future;
  }

  void _onMessage(dynamic raw) {
    Map<String, dynamic>? json;
    try {
      json = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    // Three shapes share this socket: a notification (method, no id), a request
    // the VM makes OF US (method + id), and a reply to one of our calls.
    final id = json['id'];
    if (json['method'] case final String method when id != null) {
      unawaited(_handleServerRequest(id, method, json['params']));
      return;
    }
    if (id is! int) {
      if (json
          case {
            'method': 'streamNotify',
            'params': final Map<String, dynamic> params,
          }) {
        if (params['event'] case final Map<String, dynamic> event) {
          // On the wire `streamId` is a SIBLING of `event`, not a field of it.
          // Fold it in: `Stdout` and `Stderr` both arrive as `WriteEvent`, so
          // without it a listener cannot tell app stdout from app stderr.
          if (!_events.isClosed) {
            _events.add({
              ...event,
              if (params['streamId'] case final String streamId)
                'streamId': streamId,
            });
          }
        }
      }
      return;
    }
    _timers.remove(id)?.cancel();
    final c = _pending.remove(id);
    if (c == null || c.isCompleted) return;

    if (json case {'error': final Map<String, dynamic> error}) {
      final msg = error['message'] as String? ?? '$error';
      c.completeError(XcrossError('VM Service RPC error: $msg'));
      return;
    }

    c.complete(switch (json['result']) {
      final Map<String, dynamic> result => result,
      _ => <String, dynamic>{},
    });
  }

  /// Answer a request the VM made of us. Always replies: a silent drop leaves
  /// the VM waiting forever, and an `evaluate` that never returns reads as a
  /// hang rather than an error.
  Future<void> _handleServerRequest(
      Object? id, String method, Object? rawParams) async {
    Map<String, Object?> body;
    final handler = _services[method];
    if (handler == null) {
      body = {
        'error': {'code': -32601, 'message': "method not found '$method'"},
      };
    } else {
      try {
        body = await handler(switch (rawParams) {
          final Map<String, Object?> params => params,
          _ => const {},
        });
      } on Object catch (e) {
        // 113 = kExpressionCompilationError. The VM forwards `details` to the
        // caller, which is where a compile error belongs.
        body = {
          'error': {
            'code': 113,
            'message': 'Expression compilation error',
            'data': {'details': '$e'},
          },
        };
      }
    }
    _channel?.sink.add(jsonEncode({...body, 'id': id, 'jsonrpc': '2.0'}));
  }

  void _handleClose() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    final copy = Map<int, Completer<Map<String, dynamic>>>.from(_pending);
    _pending.clear();
    for (final c in copy.values) {
      if (!c.isCompleted) {
        c.completeError(XcrossError('VM Service: connection closed'));
      }
    }
    _sub?.cancel();
    if (!_events.isClosed) _events.close();
    _channel = null;
  }
}
