import 'dart:async';
import 'dart:convert';

import 'package:cli_kit/cli_kit.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xcross_flutter/src/errors.dart';
import 'package:xcross_flutter/src/hot_reload/internal/pending_call.dart';

/// A service the VM can call back into; returns the reply body.
typedef VmServiceHandler =
    Future<Map<String, Object?>> Function(Map<String, Object?> params);

/// JSON-RPC 2.0 client for the Dart VM Service over WebSocket.
final class DartVmServiceClient {
  DartVmServiceClient();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  int _nextId = 0;
  final Map<int, PendingCall> _pending = {};
  final Map<String, VmServiceHandler> _services = {};

  // Broadcast of VM Service stream events (`streamNotify`). Callers must
  // [streamListen] first, then await [events].
  final _events = StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get events => _events.stream;

  /// Connect to the VM Service WebSocket at [url].
  Future<void> connect(
    Uri url, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    try {
      _channel = WebSocketChannel.connect(url);
      await _channel!.ready.timeout(timeout);
    } catch (e) {
      throw FlutterBuildError('VM Service connect failed: $e');
    }
    _subscription = _channel!.stream.listen(
      _onMessage,
      onError: (_) => _handleClose(),
      onDone: _handleClose,
    );
  }

  Future<void> close() async {
    try {
      await _channel?.sink.close().timeout(const Duration(milliseconds: 500));
    } on Object catch (e) {
      Log.logTrace('VM Service: close ignored: $e');
    }
    _handleClose();
  }

  /// Perform a JSON-RPC call; returns the `result` map.
  Future<Map<String, dynamic>> call(
    String method, {
    Map<String, dynamic> params = const {},
    Duration timeout = const Duration(seconds: 30),
  }) {
    final channel = _channel;
    if (channel == null) throw FlutterBuildError('VM Service: not connected');

    final id = ++_nextId;
    final completer = Completer<Map<String, dynamic>>();

    // KEEP the Timer so it can be cancelled on reply. A live Timer keeps the
    // Dart event loop alive; leaking one per RPC is why the process wouldn't
    // exit (Ctrl-C hang).
    _pending[id] = PendingCall(
      completer: completer,
      timeout: Timer(timeout, () {
        if (_pending.remove(id) != null && !completer.isCompleted) {
          completer.completeError(
            FlutterBuildError('VM Service: $method timed out'),
          );
        }
      }),
    );

    channel.sink.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );
    return completer.future;
  }

  /// Register a service the VM can call back into, e.g. `compileExpression`.
  ///
  /// A [handler] that throws becomes an error response.
  Future<void> registerService(
    String service,
    String alias,
    VmServiceHandler handler,
  ) async {
    _services[service] = handler;
    await call('registerService', params: {'service': service, 'alias': alias});
  }

  /// Subscribe to a VM Service event stream (idempotent — ignores
  /// "already subscribed").
  Future<void> streamListen(String streamId) async {
    try {
      await call('streamListen', params: {'streamId': streamId});
    } on FlutterBuildError catch (e) {
      Log.logTrace('streamListen($streamId): $e');
    }
  }

  /// Complete when a `streamNotify` event of [kind] arrives (up to [timeout]).
  ///
  /// Swallows the timeout: a device that never emits the event reports success
  /// after [timeout] rather than throwing. Callers depend on that.
  Future<Map<String, dynamic>> waitForEvent(
    String kind, {
    Duration timeout = const Duration(seconds: 60),
  }) => events
      .firstWhere((e) => e['kind'] == kind)
      .timeout(timeout, onTimeout: () => const {});

  void _onMessage(dynamic raw) {
    final Map<String, dynamic> message;
    try {
      message = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    // Three shapes share this socket: a notification (method, no id), a request
    // the VM makes OF US (method + id), and a reply to one of our calls.
    final id = message['id'];
    if (message['method'] case final String method when id != null) {
      unawaited(_handleServerRequest(id, method, message['params']));
    } else if (id is int) {
      _completeCall(id, message);
    } else {
      _emitStreamEvent(message);
    }
  }

  void _emitStreamEvent(Map<String, dynamic> message) {
    if (message case {
      'method': 'streamNotify',
      'params': final Map<String, dynamic> params,
    }) {
      if (params['event'] case final Map<String, dynamic> event
          when !_events.isClosed) {
        // On the wire `streamId` is a SIBLING of `event`, not a field of it.
        // Fold it in: `Stdout` and `Stderr` both arrive as `WriteEvent`, so
        // without it a listener cannot tell app stdout from app stderr.
        _events.add({
          ...event,
          if (params['streamId'] case final String streamId)
            'streamId': streamId,
        });
      }
    }
  }

  void _completeCall(int id, Map<String, dynamic> message) {
    final pending = _pending.remove(id);
    if (pending == null) return;
    pending.timeout.cancel();
    final completer = pending.completer;
    if (completer.isCompleted) return;

    if (message case {'error': final Map<String, dynamic> error}) {
      final detail = error['message'] as String? ?? '$error';
      completer.completeError(
        FlutterBuildError('VM Service RPC error: $detail'),
      );
      return;
    }
    completer.complete(switch (message['result']) {
      final Map<String, dynamic> result => result,
      _ => <String, dynamic>{},
    });
  }

  // Always replies: a silent drop leaves the VM waiting forever.
  Future<void> _handleServerRequest(
    Object? id,
    String method,
    Object? rawParams,
  ) async {
    final body = await _invokeService(method, rawParams);
    _channel?.sink.add(jsonEncode({...body, 'id': id, 'jsonrpc': '2.0'}));
  }

  Future<Map<String, Object?>> _invokeService(
    String method,
    Object? rawParams,
  ) async {
    final handler = _services[method];
    if (handler == null) {
      return {
        'error': {'code': -32601, 'message': "method not found '$method'"},
      };
    }
    try {
      return await handler(switch (rawParams) {
        final Map<String, Object?> params => params,
        _ => const {},
      });
    } on Object catch (e) {
      // 113 = kExpressionCompilationError. The VM forwards `details` to the
      // caller, which is where a compile error belongs.
      return {
        'error': {
          'code': 113,
          'message': 'Expression compilation error',
          'data': {'details': '$e'},
        },
      };
    }
  }

  void _handleClose() {
    final abandoned = _pending.values.toList();
    _pending.clear();
    for (final pending in abandoned) {
      pending.timeout.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(
          FlutterBuildError('VM Service: connection closed'),
        );
      }
    }
    _subscription?.cancel();
    if (!_events.isClosed) _events.close();
    _channel = null;
  }
}
