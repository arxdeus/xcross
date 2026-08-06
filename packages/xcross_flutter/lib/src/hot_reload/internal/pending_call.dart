import 'dart:async';

import 'package:meta/meta.dart';

/// An in-flight JSON-RPC call and the timer that bounds it.
@immutable
final class PendingCall {
  const PendingCall({required this.completer, required this.timeout});

  final Completer<Map<String, dynamic>> completer;
  final Timer timeout;
}
