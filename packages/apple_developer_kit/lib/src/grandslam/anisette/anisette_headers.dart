import 'dart:convert';
import 'dart:io';

import 'package:apple_developer_kit/src/grandslam/anisette/anisette_state.dart';
import 'package:crypto/crypto.dart' as crypto;

/// Cross-validated client identity used by Dadoum/Provision and xtool's
/// XADIProvider. It is intentionally stable rather than real host hardware.
const String anisetteClientInfo =
    '<MacBookPro13,2> <macOS;13.1;22C65> '
    '<com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>';

const String _defaultLocale = 'en_US';
const String _defaultTimeZone = 'America/Los_Angeles';
const String _defaultCountry = 'US';

abstract final class AnisetteHeaders {
  static Map<String, String> buildAnisetteHeaders({
    required String oneTimePassword,
    required String machineIdentifier,
    required String routingInfo,
    required String localUserUid,
    String? clientInfo,
    String? deviceId,
    String? localUserId,
  }) => {
    'X-Apple-I-MD': oneTimePassword,
    'X-Apple-I-MD-M': machineIdentifier,
    'X-Apple-I-MD-RINFO': routingInfo,
    'X-Apple-I-MD-LU':
        localUserId ?? AnisetteHeaders.anisetteLocalUserIdHash(localUserUid),
    'X-Mme-Device-Id': deviceId ?? localUserUid,
    'X-MMe-Client-Info': clientInfo ?? anisetteClientInfo,
    'X-Apple-Locale': AnisetteHeaders.anisetteSystemLocale(),
    'X-Apple-I-TimeZone': _defaultTimeZone,
    'X-Apple-I-Client-Time': AnisetteHeaders.anisetteIsoClientTime(),
  };
  static Map<String, String> buildAnisetteLookupHeaders(
    AnisetteState state, {
    String? clientInfo,
    String? deviceId,
  }) => {
    'X-MMe-Client-Info': clientInfo ?? anisetteClientInfo,
    'X-Mme-Device-Id': deviceId ?? state.localUserUid,
    'X-Apple-I-Locale': AnisetteHeaders.anisetteSystemLocale(),
    'X-Apple-I-TimeZone': _defaultTimeZone,
    'X-Apple-I-TimeZone-Offset': '${DateTime.now().timeZoneOffset.inSeconds}',
    'X-MMe-Country': _defaultCountry,
  };
  static Map<String, String> buildAnisetteProvisioningHeaders(
    AnisetteState state,
  ) => {
    'Content-Type': 'text/x-xml-plist',
    'X-Apple-I-Client-Time': AnisetteHeaders.anisetteIsoClientTime(),
    'X-Apple-I-MD-LU': AnisetteHeaders.anisetteLocalUserIdHash(
      state.localUserUid,
    ),
    'X-Mme-Device-Id': state.localUserUid,
    'X-MMe-Client-Info': anisetteClientInfo,
    'X-MMe-Country': _defaultCountry,
    'X-Apple-I-Locale': AnisetteHeaders.anisetteSystemLocale(),
    'X-Apple-I-TimeZone': _defaultTimeZone,
  };
  static String anisetteLocalUserIdHash(String localUserUid) {
    final digest = crypto.sha256.convert(utf8.encode(localUserUid));
    return digest.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
  }

  static String anisetteIsoClientTime() {
    final now = DateTime.now().toUtc();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year.toString().padLeft(4, '0')}-${two(now.month)}-${two(now.day)}'
        'T${two(now.hour)}:${two(now.minute)}:${two(now.second)}Z';
  }

  static String anisetteSystemLocale() {
    final raw = Platform.localeName
        .split(RegExp('[.@]'))
        .first
        .replaceAll('-', '_');
    return RegExp(r'^[a-zA-Z]{2,3}_[a-zA-Z]{2,4}$').hasMatch(raw)
        ? raw
        : _defaultLocale;
  }
}
