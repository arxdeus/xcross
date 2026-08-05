/// Persisted state for [AnisetteDataProvider]: the per-install
/// pseudo-identity UUID plus, once provisioning completes, the
/// provisioning marker and `routingInfo`. ADI never returns `routingInfo`
/// again after `endProvisioning`, so losing this file is unrecoverable.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:apple_developer_kit/src/errors.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// Persisted Anisette provisioning state.
@immutable
class AnisetteState {
  const AnisetteState({
    required this.localUserUid,
    this.provisioned = false,
    this.routingInfo,
  });

  factory AnisetteState.fromJson(Map<String, Object?> json) {
    final localUserUid = json['localUserUid'];
    if (localUserUid is! String || localUserUid.isEmpty) {
      throw const AppleError('anisette state: missing/invalid "localUserUid"');
    }
    final routingInfo = json['routingInfo'];
    return AnisetteState(
      localUserUid: localUserUid,
      provisioned: json['provisioned'] == true,
      routingInfo: routingInfo is String ? int.parse(routingInfo) : null,
    );
  }

  /// Random UUID generated once and persisted for the life of this install.
  /// Both `X-Apple-I-MD-LU` (its SHA-256) and `X-Mme-Device-Id` (itself)
  /// derive from this single value, matching xtool's `ADIDataProvider`.
  final String localUserUid;

  /// Whether the one-time device provisioning handshake has completed.
  final bool provisioned;

  /// `X-Apple-I-MD-RINFO`, parsed as a u64. Meaningful once [provisioned].
  final int? routingInfo;

  @useResult
  AnisetteState copyWith({bool? provisioned, int? routingInfo}) =>
      AnisetteState(
        localUserUid: localUserUid,
        provisioned: provisioned ?? this.provisioned,
        routingInfo: routingInfo ?? this.routingInfo,
      );

  Map<String, Object?> toJson() => {
    'localUserUid': localUserUid,
    'provisioned': provisioned,
    // Decimal string: routingInfo is unsigned 64-bit and JSON numbers are
    // not guaranteed to round-trip that range exactly.
    if (routingInfo != null) 'routingInfo': routingInfo.toString(),
  };

  /// A random v4 UUID from `Random.secure` - no UUID package needed for a
  /// single persisted device-identity value.
  @useResult
  static String generateUuidV4() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10xx

    String hex(int start, int end) => bytes
        .sublist(start, end)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();

    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}'
        '-${hex(8, 10)}-${hex(10, 16)}';
  }
}

/// Reads/writes [AnisetteState] to a per-user JSON config file.
class AnisetteStateStore {
  AnisetteStateStore({String? path}) : path = path ?? defaultPath();

  final String path;

  /// `<config-dir>/xcross/anisette-state.json`, where `<config-dir>` is
  /// `%APPDATA%` on Windows and `$XDG_CONFIG_HOME` (or `~/.config`)
  /// elsewhere - the same convention as `AscCredentials.defaultConfigPath`.
  @useResult
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

  /// Loads the persisted state, creating and saving a fresh one (with a
  /// new [AnisetteState.localUserUid]) if none exists yet.
  Future<AnisetteState> load() async {
    final file = File(path);
    if (!file.existsSync()) {
      final fresh = AnisetteState(localUserUid: AnisetteState.generateUuidV4());
      await save(fresh);
      return fresh;
    }
    final Object? doc;
    try {
      doc = jsonDecode(await file.readAsString());
    } on FormatException catch (e) {
      throw AppleError('$path: invalid JSON ($e)');
    }
    if (doc is! Map) throw AppleError('$path: invalid document');
    return AnisetteState.fromJson(doc.cast());
  }

  Future<void> save(AnisetteState state) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(state.toJson()));
  }
}
