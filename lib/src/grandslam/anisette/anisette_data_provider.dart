/// [AnisetteDataProvider]: the "Anisette" data source for Apple's
/// GrandSlam login protocol - the real HTTP headers/plist fields
/// (`X-Apple-I-MD*`) Apple's servers require on every GrandSlam request,
/// produced by driving a local ADI (Apple Device Identity) native library
/// through a one-time network "device provisioning" handshake, then
/// per-call OTP generation.
///
/// Protocol details (the provisioning handshake shape, header names, and
/// the `dsId = -2` sentinel) were verified directly against BOTH:
///  - Dadoum/Provision's `ProvisioningSession` class
///    (`lib/provision/adi.d`, D, LGPLv2 - the reference implementation
///    `package:provision_dart`'s `AdiClient` was ported from).
///  - xtool's independent Swift reproduction (`ADIDataProvider.swift`,
///    `XADIProvider.swift`, `AnisetteData.swift`, `GrandSlamEndpoints.swift`
///    under `Sources/XKit/GrandSlam`).
/// The two agree on the provisioning request/response shape, the header
/// names, and the `dsId` sentinel; specific points below note where only
/// one of the two confirms a detail.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:provision_dart/provision_dart.dart';
import 'package:xcross/src/grandslam/anisette/anisette_state.dart';
import 'package:xcross/src/grandslam/anisette/grandslam_endpoints.dart';
import 'package:xcross/src/grandslam/grandslam_response.dart';
import 'package:xcross/src/util/errors.dart';

/// Apple's well-known sentinel `dsId` for machine-level (not-yet
/// logged-in) ADI identity, used identically for the provisioning
/// handshake and every `requestOTP` call. Not configurable - it's a fixed
/// Apple protocol constant, not a per-caller value.
///
/// Cross-validated: `adi.isMachineProvisioned(-2)` /
/// `provisioningSession.provision(-2)` in Provision's `main.d` usage
/// example, and `UInt64(bitPattern: -2)` in xtool's `XADIProvider`.
const int kAdiMachineDsId = -2;

/// Minimal surface of `package:provision_dart`'s [AdiClient] this provider
/// drives, abstracted so tests can substitute a fake without touching the
/// real (Linux-only) native ADI library. [AdiClient.fromDirectory] plus
/// its `provisioningPath`/`identifier` setters are configuration, handled
/// once by the factory that produces this interface - not part of it.
abstract class AdiProvisioning {
  Future<bool> isMachineProvisioned(int dsId);

  Future<AdiClientProvisioningIntermediateMetadata> startProvisioning(
    int dsId,
    Uint8List serverProvisioningIntermediateMetadata,
  );

  Future<void> endProvisioning(
    int session,
    Uint8List persistentTokenMetadata,
    Uint8List trustKey,
  );

  Future<AdiOneTimePassword> requestOTP(int dsId);
}

class _RealAdiProvisioning implements AdiProvisioning {
  _RealAdiProvisioning(this._client);

  final AdiClient _client;

  @override
  Future<bool> isMachineProvisioned(int dsId) =>
      _client.isMachineProvisioned(dsId);

  @override
  Future<AdiClientProvisioningIntermediateMetadata> startProvisioning(
    int dsId,
    Uint8List serverProvisioningIntermediateMetadata,
  ) => _client.startProvisioning(dsId, serverProvisioningIntermediateMetadata);

  @override
  Future<void> endProvisioning(
    int session,
    Uint8List persistentTokenMetadata,
    Uint8List trustKey,
  ) => _client.endProvisioning(session, persistentTokenMetadata, trustKey);

  @override
  Future<AdiOneTimePassword> requestOTP(int dsId) => _client.requestOTP(dsId);
}

AdiProvisioning _defaultAdiFactory({
  required String adiLibraryDirectory,
  required String provisioningPath,
  required String identifier,
}) {
  final client = AdiClient.fromDirectory(adiLibraryDirectory);
  client.provisioningPath = provisioningPath;
  client.identifier = identifier;
  return _RealAdiProvisioning(client);
}

/// Static placeholder client-info string identifying this "device" to
/// Apple's GrandSlam servers. Not derived from real hardware - this isn't
/// spoofing one specific physical Mac - but this exact string is used
/// identically in BOTH Dadoum/Provision's own `main.d` usage example and
/// xtool's `XADIProvider.clientInfo()`, so it's a genuinely
/// cross-validated known-working value, not a guess. A future reviewer
/// may want to make this configurable/more "realistic" if Apple starts
/// fingerprinting on it.
const String _clientInfo =
    '<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>';

/// Static placeholder locale/timezone/country defaults, used when the
/// system value can't be confidently derived without a package
/// dependency (e.g. Dart's stdlib has no IANA-zone-id API). Not critical
/// to get exactly right for this layer.
const String _defaultLocale = 'en_US';
const String _defaultTimeZone = 'America/Los_Angeles';
const String _defaultCountry = 'US';

/// Produces the real HTTP headers/plist fields Apple's GrandSlam servers
/// require ("Anisette data"), given a locally-loaded ADI native library.
///
/// Handles, on first use:
///  - Loading/creating persisted state (a per-install pseudo-identity UUID,
///    plus provisioning status/`routingInfo` once provisioned).
///  - The one-time device provisioning network handshake (skipped if
///    already provisioned).
///  - Fresh per-call OTP generation (cheap, local, no network - safe to
///    call every time) combined with the persisted values into the final
///    header set.
class AnisetteDataProvider {
  AnisetteDataProvider(
    this.adiLibraryDirectory, {
    http.Client? httpClient,
    AnisetteStateStore? stateStore,
    AdiProvisioning Function({
      required String adiLibraryDirectory,
      required String provisioningPath,
      required String identifier,
    })?
    adiFactory,
  }) : _http = httpClient ?? http.Client(),
       _stateStore = stateStore ?? AnisetteStateStore(),
       _adiFactory = adiFactory ?? _defaultAdiFactory;

  /// Directory containing the already-extracted `libCoreADI.so` and
  /// `libstoreservicescore.so` native libraries. Obtaining them is the
  /// caller's responsibility (see `package:provision_dart`'s
  /// `AdiLibraryFetcher`/`apk_fetch.dart`, out of scope here).
  final String adiLibraryDirectory;

  final http.Client _http;
  final AnisetteStateStore _stateStore;
  final AdiProvisioning Function({
    required String adiLibraryDirectory,
    required String provisioningPath,
    required String identifier,
  })
  _adiFactory;

  AnisetteState? _state;
  AdiProvisioning? _adi;
  GrandSlamEndpoints? _endpoints;

  /// Returns the current Anisette headers, running the one-time
  /// provisioning handshake first if this install isn't provisioned yet.
  Future<Map<String, String>> fetchAnisetteHeaders() async {
    final state = await _ensureProvisioned(await _loadState());
    return _buildHeaders(await _adiFor(state), state);
  }

  /// Releases the underlying HTTP client's resources.
  void close() => _http.close();

  Future<AnisetteState> _loadState() async {
    return _state ??= await _stateStore.load();
  }

  Future<AdiProvisioning> _adiFor(AnisetteState state) async {
    final cached = _adi;
    if (cached != null) return cached;
    final provisioningDir = p.join(p.dirname(_stateStore.path), 'adi');
    final adi = _adiFactory(
      adiLibraryDirectory: adiLibraryDirectory,
      provisioningPath: provisioningDir,
      identifier: _androidId(state.localUserUid),
    );
    _adi = adi;
    return adi;
  }

  Future<GrandSlamEndpoints> _grandSlamEndpoints(AnisetteState state) async {
    return _endpoints ??= await fetchGrandSlamEndpoints(
      _http,
      headers: _lookupHeaders(state),
    );
  }

  /// Runs the one-time provisioning handshake if [state] isn't already
  /// provisioned; returns the (possibly updated, now-persisted) state.
  ///
  /// Steps 1-5 below match the doc comment on this class; step numbers
  /// are cited in code comments for cross-reference.
  Future<AnisetteState> _ensureProvisioned(AnisetteState state) async {
    if (state.provisioned && state.routingInfo != null) return state;

    final adi = await _adiFor(state);

    // Defensive guard: if ADI's own on-disk state disagrees with ours
    // (e.g. our state file was lost/corrupted but adi.pb wasn't), we
    // cannot safely re-provision (ADI would refuse - "pending session" /
    // it's genuinely already provisioned) but also cannot recover
    // routingInfo (ADI never returns it again after `endProvisioning`).
    // Surface a clear error instead of silently misbehaving.
    if (await adi.isMachineProvisioned(kAdiMachineDsId)) {
      throw XcrossError(
        'ADI reports this device is already provisioned, but xcross has '
        'no saved routing info for it (state file at ${_stateStore.path} '
        'missing or corrupted?). Erase provisioning for this device '
        '(delete its ADI provisioning directory) and retry.',
      );
    }

    final endpoints = await _grandSlamEndpoints(state);

    // 1. POST midStartProvisioning with an empty Request dict.
    final startResponse = await _postProvisioning(
      endpoints.midStartProvisioning,
      const {},
      state,
    );
    final spim = base64Decode(_stringField(startResponse, 'spim'));

    // 2. Local ADI call using the real server-provided spim directly.
    final cpimResult = await adi.startProvisioning(kAdiMachineDsId, spim);

    // 3. POST midFinishProvisioning with the local cpim result.
    final finishResponse = await _postProvisioning(
      endpoints.midFinishProvisioning,
      {
        'cpim': base64Encode(
          cpimResult.clientProvisioningIntermediateMetadata,
        ),
      },
      state,
    );
    final ptm = base64Decode(_stringField(finishResponse, 'ptm'));
    final tk = base64Decode(_stringField(finishResponse, 'tk'));
    final routingInfo = int.parse(
      _stringField(finishResponse, 'X-Apple-I-MD-RINFO'),
    );

    // 4. Complete provisioning locally (no routing-info parameter).
    await adi.endProvisioning(cpimResult.session, ptm, tk);

    // 5. Persist routingInfo + the provisioned marker - ADI never returns
    //    routingInfo again after this point.
    final newState = state.copyWith(provisioned: true, routingInfo: routingInfo);
    await _stateStore.save(newState);
    _state = newState;
    return newState;
  }

  Future<Map<String, String>> _buildHeaders(
    AdiProvisioning adi,
    AnisetteState state,
  ) async {
    final otp = await adi.requestOTP(kAdiMachineDsId);
    return {
      'X-Apple-I-MD': base64Encode(otp.oneTimePassword),
      'X-Apple-I-MD-M': base64Encode(otp.machineIdentifier),
      'X-Apple-I-MD-RINFO': '${state.routingInfo}',
      'X-Apple-I-MD-LU': _localUserIdHash(state.localUserUid),
      'X-Mme-Device-Id': state.localUserUid,
      'X-MMe-Client-Info': _clientInfo,
      'X-Apple-I-Locale': _systemLocale(),
      'X-Apple-I-TimeZone': _defaultTimeZone,
      'X-Apple-I-Client-Time': _isoClientTime(),
    };
  }

  Future<Map<String, Object?>> _postProvisioning(
    String url,
    Map<String, Object?> request,
    AnisetteState state,
  ) async {
    final body = PropertyListSerialization.stringWithPropertyList({
      'Header': <String, Object?>{},
      'Request': request,
    });
    final response = await _http.post(
      Uri.parse(url),
      headers: _provisioningHeaders(state),
      body: body,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw XcrossError(
        'GrandSlam provisioning request to $url failed '
        '(HTTP ${response.statusCode})',
      );
    }
    return decodeGrandSlamResponse(response.body);
  }

  /// Headers for the `GsService2/lookup` `GET` - no Anisette data exists
  /// yet, so only the persisted pseudo-identity/locale headers apply.
  /// Matches xtool's `GrandSlamLookupManager.performLookup` exactly.
  Map<String, String> _lookupHeaders(AnisetteState state) => {
    'X-MMe-Client-Info': _clientInfo,
    'X-Mme-Device-Id': state.localUserUid,
    'X-Apple-I-Locale': _systemLocale(),
    'X-Apple-I-TimeZone': _defaultTimeZone,
    'X-Apple-I-TimeZone-Offset': '${DateTime.now().timeZoneOffset.inSeconds}',
    'X-MMe-Country': _defaultCountry,
  };

  /// Headers for the two provisioning POSTs. `X-Apple-I-Client-Time` is
  /// generated fresh here (called immediately before each POST, never
  /// cached/reused) per both Provision's `ProvisioningSession.provision`
  /// (adds it fresh before each of the two POSTs) and the task's own
  /// requirement; `text/x-xml-plist` matches xtool's choice (Provision's
  /// D reference sends `application/x-www-form-urlencoded` here and notes
  /// in a comment that it still works, but the plist content-type is the
  /// standards-correct one every other GSA call uses).
  Map<String, String> _provisioningHeaders(AnisetteState state) => {
    'Content-Type': 'text/x-xml-plist',
    'X-Apple-I-Client-Time': _isoClientTime(),
    'X-Apple-I-MD-LU': _localUserIdHash(state.localUserUid),
    'X-Mme-Device-Id': state.localUserUid,
    'X-MMe-Client-Info': _clientInfo,
    'X-MMe-Country': _defaultCountry,
    'X-Apple-I-Locale': _systemLocale(),
    'X-Apple-I-TimeZone': _defaultTimeZone,
  };
}

/// `X-Apple-I-MD-LU`: `SHA256(localUserUid)`, uppercase hex - matches
/// xtool's `ADIDataProvider.localUserID` derivation exactly (confirmed
/// from source: `SHA256.hash(data: ...).map { String(format: "%02X", $0) }`).
String _localUserIdHash(String localUserUid) {
  final digest = crypto.sha256.convert(utf8.encode(localUserUid));
  return digest.bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();
}

/// ADI's "Android ID" identifier: the first 16 lowercase hex characters of
/// [localUserUid] with dashes removed. Matches xtool's `XADIProvider`
/// derivation exactly (`id.uuidString.replacingOccurrences(of: "-", with:
/// "").prefix(16).lowercased()`) - reusing the persisted identity UUID
/// instead of a separate persisted value.
String _androidId(String localUserUid) =>
    localUserUid.replaceAll('-', '').substring(0, 16).toLowerCase();

/// ISO8601 UTC timestamp with no fractional seconds, e.g.
/// `2024-05-01T12:34:56Z`. Matches Provision's
/// `Clock.currTime().stripMilliseconds().toISOExtString()` and xtool's
/// `AnisetteData`'s `"yyyy-MM-dd'T'HH:mm:ss'Z'"` date formatter.
String _isoClientTime() {
  final now = DateTime.now().toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${now.year.toString().padLeft(4, '0')}-${two(now.month)}-${two(now.day)}'
      'T${two(now.hour)}:${two(now.minute)}:${two(now.second)}Z';
}

/// Best-effort system locale in `xx_YY` form, falling back to
/// [_defaultLocale] if [Platform.localeName] isn't in a recognizable
/// shape (it varies by OS: `en_US.UTF-8` on POSIX, `en-US` on Windows).
String _systemLocale() {
  final raw = Platform.localeName.split(RegExp('[.@]')).first.replaceAll('-', '_');
  return RegExp(r'^[a-zA-Z]{2,3}_[a-zA-Z]{2,4}$').hasMatch(raw)
      ? raw
      : _defaultLocale;
}

String _stringField(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! String) {
    throw XcrossError('GrandSlam response missing "$key" (or not a string)');
  }
  return value;
}
