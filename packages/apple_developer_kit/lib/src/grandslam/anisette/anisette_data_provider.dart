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
import 'dart:typed_data';

import 'package:apple_developer_kit/src/adi/adi_client.dart'
    show
        AdiClient,
        AdiClientProvisioningIntermediateMetadata,
        AdiOneTimePassword;
import 'package:apple_developer_kit/src/apple_http_client.dart';
import 'package:apple_developer_kit/src/errors.dart';
import 'package:apple_developer_kit/src/grandslam/anisette/anisette_headers.dart';
import 'package:apple_developer_kit/src/grandslam/anisette/anisette_provider.dart';
import 'package:apple_developer_kit/src/grandslam/anisette/anisette_state.dart';
import 'package:apple_developer_kit/src/grandslam/anisette/grandslam_endpoints.dart';
import 'package:apple_developer_kit/src/grandslam/grandslam_response.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:propertylistserialization/propertylistserialization.dart';

export 'package:apple_developer_kit/src/adi/adi_client.dart'
    show AdiClientProvisioningIntermediateMetadata, AdiOneTimePassword;

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
/// real (Linux) native ADI library. [AdiClient.fromDirectory] plus its
/// `provisioningPath`/`identifier` setters are configuration, handled once
/// by the factory that produces this interface - not part of it.
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
  // ADI on Windows is happier with forward-slash provisioning paths (bionic
  // open() stubs translate them); trailing slash matches Provision usage.
  final normalizedPath = provisioningPath.replaceAll(r'\', '/');
  client.provisioningPath = normalizedPath.endsWith('/')
      ? normalizedPath
      : '$normalizedPath/';
  client.identifier = identifier;
  return _RealAdiProvisioning(client);
}

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
class AnisetteDataProvider implements AnisetteProvider {
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
  }) : _http = httpClient ?? createAppleHttpClient(),
       _stateStore = stateStore ?? AnisetteStateStore(),
       _adiFactory = adiFactory ?? _defaultAdiFactory;

  /// Directory containing the already-extracted `libCoreADI.so` and
  /// `libstoreservicescore.so` native libraries. On Linux x86_64, `xcross auth`
  /// can fetch these via provision_dart's AdiLibraryFetcher; otherwise the
  /// caller supplies them.
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
  @override
  Future<Map<String, String>> fetchAnisetteHeaders() async {
    final state = await _ensureProvisioned(await _loadState());
    return _buildHeaders(await _adiFor(state), state);
  }

  /// Resolves and caches the GrandSlam URL bag using this install's
  /// persisted pseudo-identity. Useful for callers that also need to send
  /// regular `o=...` GrandSlam operations with the same Anisette provider.
  @override
  Future<GrandSlamEndpoints> resolveGrandSlamEndpoints() async {
    return _grandSlamEndpoints(await _loadState());
  }

  /// Releases the underlying HTTP client's resources.
  @override
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
      headers: buildAnisetteLookupHeaders(state),
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
      throw AppleError(
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
      {'cpim': base64Encode(cpimResult.clientProvisioningIntermediateMetadata)},
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
    final newState = state.copyWith(
      provisioned: true,
      routingInfo: routingInfo,
    );
    await _stateStore.save(newState);
    _state = newState;
    return newState;
  }

  Future<Map<String, String>> _buildHeaders(
    AdiProvisioning adi,
    AnisetteState state,
  ) async {
    final otp = await adi.requestOTP(kAdiMachineDsId);
    return buildAnisetteHeaders(
      oneTimePassword: base64Encode(otp.oneTimePassword),
      machineIdentifier: base64Encode(otp.machineIdentifier),
      routingInfo: '${state.routingInfo}',
      localUserUid: state.localUserUid,
    );
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
    final response = await sendGrandSlamRequest(
      _http,
      method: 'POST',
      url: url,
      operation: 'Anisette provisioning',
      headers: buildAnisetteProvisioningHeaders(state),
      body: body,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AppleError(
        'GrandSlam provisioning request to $url failed '
        '(HTTP ${response.statusCode})',
      );
    }
    return decodeGrandSlamResponse(response.body);
  }
}

/// ADI's "Android ID" identifier: the first 16 lowercase hex characters of
/// [localUserUid] with dashes removed. Matches xtool's `XADIProvider`
/// derivation exactly (`id.uuidString.replacingOccurrences(of: "-", with:
/// "").prefix(16).lowercased()`) - reusing the persisted identity UUID
/// instead of a separate persisted value.
String _androidId(String localUserUid) =>
    localUserUid.replaceAll('-', '').substring(0, 16).toLowerCase();

String _stringField(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! String) {
    throw AppleError('GrandSlam response missing "$key" (or not a string)');
  }
  return value;
}
