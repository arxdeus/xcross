// Tests for [AnisetteState]/[AnisetteStateStore]: JSON round-trip and the
// "create fresh state with a generated UUID on first load" behavior. No
// network/native-ADI involved - this is pure persisted-state logic.
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/grandslam/anisette/anisette_state.dart';

void main() {
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
    final uuid = generateUuidV4();
    expect(
      uuid,
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
    // Not the same value every call.
    expect(generateUuidV4(), isNot(uuid));
  });

  test('load() creates a fresh state file with a generated UUID when none exists', () async {
    expect(File(statePath).existsSync(), isFalse);

    final store = AnisetteStateStore(path: statePath);
    final state = await store.load();

    expect(File(statePath).existsSync(), isTrue);
    expect(state.localUserUid, isNotEmpty);
    expect(state.provisioned, isFalse);
    expect(state.routingInfo, isNull);

    // Loading again returns the same persisted UUID, not a new one.
    final reloaded = await AnisetteStateStore(path: statePath).load();
    expect(reloaded.localUserUid, state.localUserUid);
  });

  test('save/load round-trips provisioned state + routingInfo (u64-safe)', () async {
    final store = AnisetteStateStore(path: statePath);
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
    // ignore: avoid_js_rounded_ints
    const bigRoutingInfo = 9223372036854775800; // near Dart int max
    const state = AnisetteState(
      localUserUid: 'abc12345-6789-4abc-8def-0123456789ab',
      provisioned: true,
      routingInfo: bigRoutingInfo,
    );

    await store.save(state);
    final reloaded = await AnisetteStateStore(path: statePath).load();

    expect(reloaded.localUserUid, state.localUserUid);
    expect(reloaded.provisioned, isTrue);
    expect(reloaded.routingInfo, bigRoutingInfo);
  });

  test('routingInfo is stored as a JSON string, not a number', () async {
    final store = AnisetteStateStore(path: statePath);
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
    const state = AnisetteState(
      localUserUid: 'uid',
    );
    final updated = state.copyWith(provisioned: true, routingInfo: 7);
    expect(updated.localUserUid, 'uid');
    expect(updated.provisioned, isTrue);
    expect(updated.routingInfo, 7);
  });
}
