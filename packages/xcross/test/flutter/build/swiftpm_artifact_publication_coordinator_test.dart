import 'dart:async';

import 'package:meta/meta.dart';
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_publication_coordinator.dart';

void main() {
  for (final phase in ['open', 'acquire', 'release', 'close']) {
    test('$phase failure always releases same-destination queue', () async {
      final provider = FailingPublicationLockProvider(phase);
      final coordinator = SwiftPmPublicationCoordinator(
        locks: provider,
        pathKey: (path) => path,
      );
      final first = coordinator.run('/artifact', () async => 1);
      final firstCheck = expectLater(first, throwsStateError);
      final next = coordinator.run('/artifact', () async => 2);
      final unrelated = coordinator.run('/other-artifact', () async => 3);
      await firstCheck;
      expect(await next.timeout(const Duration(seconds: 1)), 2);
      expect(await unrelated.timeout(const Duration(seconds: 1)), 3);
      expect(provider.closed, phase == 'open' ? 2 : 3);
    });
  }

  test(
    'serializes equivalent destinations without blocking other keys',
    () async {
      final provider = FailingPublicationLockProvider('none');
      final coordinator = SwiftPmPublicationCoordinator(
        locks: provider,
        pathKey: (path) => path.toLowerCase(),
      );
      final entered = Completer<void>();
      final release = Completer<void>();
      var secondEntered = false;
      final first = coordinator.run('/ARTIFACT', () async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      final second = coordinator.run('/artifact', () async {
        secondEntered = true;
      });
      await coordinator.run('/independent', () async {});
      expect(secondEntered, isFalse);
      release.complete();
      await Future.wait([first, second]);
      expect(secondEntered, isTrue);
    },
  );
}

@internal
final class FailingPublicationLockProvider
    implements SwiftPmPublicationLockProvider {
  FailingPublicationLockProvider(this.phase);
  final String phase;
  int calls = 0;
  int closed = 0;

  @override
  Future<SwiftPmPublicationLock> open(String path) async {
    final fail = calls++ == 0;
    if (fail && phase == 'open') throw StateError('open');
    return FailingPublicationLock(this, fail: fail);
  }
}

@internal
final class FailingPublicationLock implements SwiftPmPublicationLock {
  const FailingPublicationLock(this.provider, {required this.fail});
  final FailingPublicationLockProvider provider;
  final bool fail;
  @override
  Future<void> acquire() async {
    if (fail && provider.phase == 'acquire') throw StateError('acquire');
  }

  @override
  Future<void> release() async {
    if (fail && provider.phase == 'release') throw StateError('release');
  }

  @override
  Future<void> close() async {
    provider.closed++;
    if (fail && provider.phase == 'close') throw StateError('close');
  }
}
