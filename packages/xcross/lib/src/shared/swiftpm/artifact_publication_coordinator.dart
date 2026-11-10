import 'dart:async';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

@internal
abstract interface class SwiftPmPublicationLockProvider {
  Future<SwiftPmPublicationLock> open(String path);
}

@internal
abstract interface class SwiftPmPublicationLock {
  Future<void> acquire();
  Future<void> release();
  Future<void> close();
}

@internal
final class SwiftPmPublicationCoordinator {
  SwiftPmPublicationCoordinator({required this.locks, required this.pathKey});
  final SwiftPmPublicationLockProvider locks;
  final String Function(String) pathKey;
  final Map<String, Future<void>> _tails = {};

  Future<T> run<T>(String destination, Future<T> Function() action) async {
    final key = pathKey(p.normalize(p.absolute(destination)));
    final previous = _tails[key];
    final done = Completer<void>();
    final tail = done.future;
    _tails[key] = tail;
    SwiftPmPublicationLock? lock;
    var acquired = false;
    try {
      if (previous != null) await previous;
      lock = await locks.open('$key.xcross-publication.lock');
      await lock.acquire();
      acquired = true;
      return await action();
    } finally {
      try {
        try {
          if (acquired) await lock!.release();
        } finally {
          await lock?.close();
        }
      } finally {
        done.complete();
        if (identical(_tails[key], tail)) {
          final removed = _tails.remove(key);
          assert(identical(removed, tail), 'publication tail changed');
        }
      }
    }
  }
}
