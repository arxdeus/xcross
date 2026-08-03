/// Small persisted key-value state for [AnisetteDataProvider]: the
/// per-install pseudo-identity UUID, and (once provisioning has completed)
/// the provisioning-done marker plus `routingInfo`, which the ADI native
/// layer never returns again after `endProvisioning` - if it isn't saved
/// here, it can't be reconstructed.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:apple_developer_kit/src/errors.dart';
import 'package:path/path.dart' as p;

/// Persisted Anisette provisioning state.
class AnisetteState {
  const AnisetteState({
    required this.localUserUid,
    this.provisioned = false,
    this.routingInfo,
  });

  /// Random UUID generated once and persisted for the life of this
  /// install. Used to derive both `X-Apple-I-MD-LU` (its SHA-256 hex) and
  /// `X-Mme-Device-Id` (itself), matching xtool's `ADIDataProvider` (which
  /// derives both headers from a single stored `localUserUID`, not two
  /// independent identifiers - confirmed directly from its source).
  final String localUserUid;

  /// Whether the one-time device provisioning handshake has completed.
  final bool provisioned;

  /// `X-Apple-I-MD-RINFO`, parsed as a u64. Only meaningful once
  /// [provisioned] is true.
  final int? routingInfo;

  AnisetteState copyWith({bool? provisioned, int? routingInfo}) =>
      AnisetteState(
        localUserUid: localUserUid,
        provisioned: provisioned ?? this.provisioned,
        routingInfo: routingInfo ?? this.routingInfo,
      );

  Map<String, Object?> toJson() => {
    'localUserUid': localUserUid,
    'provisioned': provisioned,
    // Stored as a decimal string: routingInfo is an unsigned 64-bit value
    // and JSON numbers aren't guaranteed to round-trip that range exactly.
    if (routingInfo != null) 'routingInfo': routingInfo.toString(),
  };

  factory AnisetteState.fromJson(Map<String, Object?> json) {
    final localUserUid = json['localUserUid'];
    if (localUserUid is! String || localUserUid.isEmpty) {
      throw AppleError('anisette state: missing/invalid "localUserUid"');
    }
    final routingInfoStr = json['routingInfo'];
    return AnisetteState(
      localUserUid: localUserUid,
      provisioned: json['provisioned'] == true,
      routingInfo: routingInfoStr is String ? int.parse(routingInfoStr) : null,
    );
  }
}

/// Reads/writes [AnisetteState] to a per-user JSON config file.
class AnisetteStateStore {
  AnisetteStateStore({String? path}) : _path = path ?? defaultPath();

  final String _path;

  String get path => _path;

  /// `<config-dir>/xcross/anisette-state.json`, using the same per-user
  /// config-dir convention as `AscCredentials.defaultConfigPath` in
  /// `appstoreconnect/asc_config.dart` (replicated here since that helper
  /// is private to that file): `%APPDATA%/xcross` on Windows,
  /// `$XDG_CONFIG_HOME/xcross` (falling back to `~/.config/xcross`)
  /// elsewhere.
  static String defaultPath() =>
      p.join(_configDir(), 'xcross', 'anisette-state.json');

  static String _configDir() {
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      if (appData != null && appData.isNotEmpty) return appData;
    }
    final xdg = Platform.environment['XDG_CONFIG_HOME'];
    if (xdg != null && xdg.isNotEmpty) return xdg;
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    return p.join(home, '.config');
  }

  /// Loads the persisted state, creating a fresh one (with a newly
  /// generated [AnisetteState.localUserUid]) if none exists yet.
  Future<AnisetteState> load() async {
    final file = File(_path);
    if (!file.existsSync()) {
      final fresh = AnisetteState(localUserUid: generateUuidV4());
      await save(fresh);
      return fresh;
    }
    final Object? doc;
    try {
      doc = jsonDecode(await file.readAsString());
    } on FormatException catch (e) {
      throw AppleError('$_path: invalid JSON ($e)');
    }
    if (doc is! Map) {
      throw AppleError('$_path: invalid document');
    }
    return AnisetteState.fromJson(doc.cast());
  }

  Future<void> save(AnisetteState state) async {
    final file = File(_path);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(state.toJson()));
  }
}

/// Generates a random (v4) UUID string using `dart:math`'s `Random.secure`
/// - no dependency on a UUID-generation package for one-shot, non-crypto
/// device identity, unlike the `dart:math`-seeded RNGs, `Random.secure` is
/// suitable here since this value is persisted and reused, not just a
/// throwaway.
String generateUuidV4() {
  final rand = Random.secure();
  final bytes = List<int>.generate(16, (_) => rand.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10xx

  String hex(int start, int end) => bytes
      .sublist(start, end)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();

  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}
