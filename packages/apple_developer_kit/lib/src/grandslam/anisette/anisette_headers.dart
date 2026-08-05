import 'dart:convert';
import 'dart:io';

import 'package:apple_developer_kit/src/grandslam/anisette/anisette_state.dart';
import 'package:crypto/crypto.dart' as crypto;

/// Client identity string Apple's servers expect. Cross-validated against
/// Dadoum/Provision and xtool's `XADIProvider`: intentionally a stable
/// fixed value, never real host hardware. Do not "normalize" it.
const String anisetteClientInfo =
    '<MacBookPro13,2> <macOS;13.1;22C65> '
    '<com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>';

const String _defaultLocale = 'en_US';
const String _defaultTimeZone = 'America/Los_Angeles';
const String _defaultCountry = 'US';

/// Builders for the `X-Apple-*`/`X-Mme-*` header sets GrandSlam requires.
/// Every header name, spelling, and casing below is a protocol constant.
abstract final class AnisetteHeaders {
  /// Headers accompanying an authenticated GrandSlam request.
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
    'X-Apple-I-MD-LU': localUserId ?? anisetteLocalUserIdHash(localUserUid),
    'X-Mme-Device-Id': deviceId ?? localUserUid,
    'X-MMe-Client-Info': clientInfo ?? anisetteClientInfo,
    'X-Apple-Locale': anisetteSystemLocale(),
    'X-Apple-I-TimeZone': _defaultTimeZone,
    'X-Apple-I-Client-Time': anisetteIsoClientTime(),
  };

  /// Headers for the GrandSlam endpoint-bag lookup, which runs before any
  /// ADI identity exists (hence no OTP/machine-identifier headers).
  static Map<String, String> buildAnisetteLookupHeaders(
    AnisetteState state, {
    String? clientInfo,
    String? deviceId,
  }) => {
    'X-MMe-Client-Info': clientInfo ?? anisetteClientInfo,
    'X-Mme-Device-Id': deviceId ?? state.localUserUid,
    'X-Apple-I-Locale': anisetteSystemLocale(),
    'X-Apple-I-TimeZone': _defaultTimeZone,
    'X-Apple-I-TimeZone-Offset': '${DateTime.now().timeZoneOffset.inSeconds}',
    'X-MMe-Country': _defaultCountry,
  };

  /// Headers for the one-time device provisioning POSTs.
  static Map<String, String> buildAnisetteProvisioningHeaders(
    AnisetteState state,
  ) => {
    'Content-Type': 'text/x-xml-plist',
    'X-Apple-I-Client-Time': anisetteIsoClientTime(),
    'X-Apple-I-MD-LU': anisetteLocalUserIdHash(state.localUserUid),
    'X-Mme-Device-Id': state.localUserUid,
    'X-MMe-Client-Info': anisetteClientInfo,
    'X-MMe-Country': _defaultCountry,
    'X-Apple-I-Locale': anisetteSystemLocale(),
    'X-Apple-I-TimeZone': _defaultTimeZone,
  };

  /// `X-Apple-I-MD-LU`: uppercase hex SHA-256 of the install's identity UUID.
  static String anisetteLocalUserIdHash(String localUserUid) => crypto.sha256
      .convert(utf8.encode(localUserUid))
      .bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();

  /// `X-Apple-I-Client-Time`: second-precision UTC ISO-8601. Deliberately
  /// hand-built - `toIso8601String()` would append milliseconds.
  static String anisetteIsoClientTime() {
    final now = DateTime.now().toUtc();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year.toString().padLeft(4, '0')}'
        '-${two(now.month)}-${two(now.day)}'
        'T${two(now.hour)}:${two(now.minute)}:${two(now.second)}Z';
  }

  /// The host locale as `ll_CC`, falling back to [_defaultLocale] when the
  /// platform reports something Apple would not recognise.
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
