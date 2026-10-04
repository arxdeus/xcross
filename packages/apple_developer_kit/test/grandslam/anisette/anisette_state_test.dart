// Tests for [AnisetteState]/[AnisetteStateStore]: JSON round-trip and the
// "create fresh state with a generated UUID on first load" behavior. No
// network/native-ADI involved - this is pure persisted-state logic.
import 'dart:io';

import 'package:apple_developer_kit/src/errors.dart';
import 'package:apple_developer_kit/src/grandslam/anisette/anisette_state.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/host_services.dart';
import '../../support/mapped_apple_fixture.dart';

void main() {
  test(
    'mapped filesystem preserves pseudo identity and unsigned routing info',
    () async {
      final fixture = MappedAppleFixture();
      addTearDown(fixture.dispose);
      final store = AnisetteStateStore(hostServices: fixture.services);
      final fresh = await store.load();
      final state = fresh.copyWith(
        provisioned: true,
        routingInfo: int.parse('9007199254740993'),
      );
      await store.save(state);
      final loaded = await AnisetteStateStore(
        hostServices: fixture.services,
      ).load();
      expect(loaded.localUserUid, fresh.localUserUid);
      expect(loaded.provisioned, isTrue);
      expect(loaded.routingInfo, int.parse('9007199254740993'));
      expect(store.provisioningDirectory, fixture.path('config/xcross/adi'));
      expect(File(store.path).existsSync(), isFalse);
      expect(fixture.permissions.hardened, hasLength(2));
      fixture.fileSystem.file(store.path).writeAsStringSync('{broken');
      await expectLater(store.load(), throwsA(isA<AppleError>()));
    },
  );

  late Directory tempDir;
  late String statePath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('xcross_anisette_state_test');
    statePath = p.join(tempDir.path, 'anisette-state.json');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('generateUuidV4 produces well-formed v4 UUIDs', () {
    final uuid = AnisetteState.generateUuidV4();
    expect(
      uuid,
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
    // Not the same value every call.
    expect(AnisetteState.generateUuidV4(), isNot(uuid));
  });

  test(
    'load() creates a fresh state file with a generated UUID when none exists',
    () async {
      expect(File(statePath).existsSync(), isFalse);

      final store = AnisetteStateStore(
        path: statePath,
        hostServices: testHostServices,
      );
      final state = await store.load();

      expect(File(statePath).existsSync(), isTrue);
      expect(state.localUserUid, isNotEmpty);
      expect(state.provisioned, isFalse);
      expect(state.routingInfo, isNull);

      // Loading again returns the same persisted UUID, not a new one.
      final reloaded = await AnisetteStateStore(
        path: statePath,
        hostServices: testHostServices,
      ).load();
      expect(reloaded.localUserUid, state.localUserUid);
    },
  );

  test(
    'save/load round-trips provisioned state + routingInfo (u64-safe)',
    () async {
      final store = AnisetteStateStore(
        path: statePath,
        hostServices: testHostServices,
      );
      // A value that would not round-trip through a JSON double (>2^53).
      // (True near-2^64 values aren't representable at all: routingInfo is
      // stored as a Dart `int`, which is 64-bit *signed* on the VM - values
      // above 2^63-1 can't round-trip. Apple's observed routingInfo values
      // are small, so this is an acceptable, documented ceiling rather than
      // a bug worth a BigInt migration for.)
      // xcross is a Dart CLI tool, never compiled to JS; the point of this
      // literal is to exceed double precision (2^53), which is exactly what
      // routingInfo's string-based JSON storage (AnisetteState.toJson) is
      // meant to survive.
      final bigRoutingInfo = int.parse(
        '9223372036854775800',
      ); // near Dart int max
      final state = AnisetteState(
        localUserUid: 'abc12345-6789-4abc-8def-0123456789ab',
        provisioned: true,
        routingInfo: bigRoutingInfo,
      );

      await store.save(state);
      final reloaded = await AnisetteStateStore(
        path: statePath,
        hostServices: testHostServices,
      ).load();

      expect(reloaded.localUserUid, state.localUserUid);
      expect(reloaded.provisioned, isTrue);
      expect(reloaded.routingInfo, bigRoutingInfo);
    },
  );

  test('routingInfo is stored as a JSON string, not a number', () async {
    final store = AnisetteStateStore(
      path: statePath,
      hostServices: testHostServices,
    );
    await store.save(
      const AnisetteState(
        localUserUid: 'abc12345-6789-4abc-8def-0123456789ab',
        provisioned: true,
        routingInfo: 42,
      ),
    );
    final raw = await File(statePath).readAsString();
    expect(raw, contains('"routingInfo":"42"'));
  });

  test('copyWith preserves unspecified fields', () {
    const state = AnisetteState(localUserUid: 'uid');
    final updated = state.copyWith(provisioned: true, routingInfo: 7);
    expect(updated.localUserUid, 'uid');
    expect(updated.provisioned, isTrue);
    expect(updated.routingInfo, 7);
  });
}
