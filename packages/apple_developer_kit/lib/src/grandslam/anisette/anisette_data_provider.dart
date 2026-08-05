/// "Anisette" data for Apple's GrandSlam protocol: the `X-Apple-I-MD*`
/// headers Apple's servers require on every request, produced by driving a
/// local ADI (Apple Device Identity) native library through a one-time
/// network provisioning handshake and then generating an OTP per call.
///
/// The handshake shape, header names, and the `dsId = -2` sentinel are
/// cross-validated against Dadoum/Provision's `ProvisioningSession` (D)
/// and xtool's independent Swift reproduction (`ADIDataProvider.swift`,
/// `XADIProvider.swift`). The two agree on all three.
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

/// Apple's sentinel `dsId` for machine-level (not-yet-signed-in) ADI
/// identity, used for both provisioning and every `requestOTP`. A fixed
/// protocol constant, not a per-caller value.
const int kAdiMachineDsId = -2;

/// Builds the [AdiProvisioning] backing an [AnisetteDataProvider].
typedef AdiProvisioningFactory =
    AdiProvisioning Function({
      required String adiLibraryDirectory,
      required String provisioningPath,
      required String identifier,
    });

/// The slice of `AdiClient` this provider drives, extracted so tests can
/// substitute a fake instead of the real (Linux) native ADI library.
/// Construction and configuration are the factory's job, not part of this.
abstract interface class AdiProvisioning {
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

/// Produces Anisette headers from a locally-loaded ADI native library.
///
/// On first use it loads or creates the persisted pseudo-identity, runs
/// the one-time provisioning handshake, and saves `routingInfo`. After
/// that each call only generates a fresh OTP, which is local and cheap.
class AnisetteDataProvider implements AnisetteProvider {
  AnisetteDataProvider(
    this.adiLibraryDirectory, {
    http.Client? httpClient,
    AnisetteStateStore? stateStore,
    AdiProvisioningFactory? adiFactory,
  }) : _http = httpClient ?? AppleHttp.createAppleHttpClient(),
       _stateStore = stateStore ?? AnisetteStateStore(),
       _adiFactory = adiFactory ?? _defaultAdiFactory;

  /// Directory holding the extracted `libCoreADI.so` and
  /// `libstoreservicescore.so`. On Linux x86_64 `xcross auth` can fetch
  /// these via provision_dart's AdiLibraryFetcher; otherwise the caller
  /// supplies them.
  final String adiLibraryDirectory;

  final http.Client _http;
  final AnisetteStateStore _stateStore;
  final AdiProvisioningFactory _adiFactory;

  AnisetteState? _state;
  AdiProvisioning? _adi;
  GrandSlamEndpoints? _endpoints;

  /// Current Anisette headers, running the one-time provisioning
  /// handshake first if this install is not provisioned yet.
  @override
  Future<Map<String, String>> fetchAnisetteHeaders() async {
    final state = await _ensureProvisioned(await _loadState());
    final otp = await _adiFor(state).requestOTP(kAdiMachineDsId);
    return AnisetteHeaders.buildAnisetteHeaders(
      oneTimePassword: base64Encode(otp.oneTimePassword),
      machineIdentifier: base64Encode(otp.machineIdentifier),
      routingInfo: '${state.routingInfo}',
      localUserUid: state.localUserUid,
    );
  }

  /// Resolves and caches the GrandSlam URL bag using this install's
  /// persisted pseudo-identity, for callers that also send `o=...`
  /// operations through the same provider.
  @override
  Future<GrandSlamEndpoints> resolveGrandSlamEndpoints() async =>
      _grandSlamEndpoints(await _loadState());

  /// Releases the underlying HTTP client's resources.
  @override
  void close() => _http.close();

  Future<AnisetteState> _loadState() async =>
      _state ??= await _stateStore.load();

  AdiProvisioning _adiFor(AnisetteState state) => _adi ??= _adiFactory(
    adiLibraryDirectory: adiLibraryDirectory,
    provisioningPath: p.join(p.dirname(_stateStore.path), 'adi'),
    identifier: _androidId(state.localUserUid),
  );

  Future<GrandSlamEndpoints> _grandSlamEndpoints(AnisetteState state) async =>
      _endpoints ??= await GrandSlamEndpoints.fetchGrandSlamEndpoints(
        _http,
        headers: AnisetteHeaders.buildAnisetteLookupHeaders(state),
      );

  /// Runs the one-time provisioning handshake unless [state] already
  /// carries its result; returns the persisted, up-to-date state.
  Future<AnisetteState> _ensureProvisioned(AnisetteState state) async {
    if (state.provisioned && state.routingInfo != null) return state;

    final adi = _adiFor(state);

    // If ADI's own on-disk state disagrees with ours we cannot recover:
    // re-provisioning would be refused, and ADI never returns routingInfo
    // again after endProvisioning. Fail loudly rather than misbehave.
    if (await adi.isMachineProvisioned(kAdiMachineDsId)) {
      throw AppleError(
        'ADI reports this device is already provisioned, but xcross has '
        'no saved routing info for it (state file at ${_stateStore.path} '
        'missing or corrupted?). Erase provisioning for this device '
        '(delete its ADI provisioning directory) and retry.',
      );
    }

    final endpoints = await _grandSlamEndpoints(state);

    final start = await _postProvisioning(
      endpoints.midStartProvisioning,
      const {},
      state,
    );
    final spim = base64Decode(GrandSlamResponse.stringField(start, 'spim'));

    final cpim = await adi.startProvisioning(kAdiMachineDsId, spim);

    final finish = await _postProvisioning(endpoints.midFinishProvisioning, {
      'cpim': base64Encode(cpim.clientProvisioningIntermediateMetadata),
    }, state);
    final ptm = base64Decode(GrandSlamResponse.stringField(finish, 'ptm'));
    final tk = base64Decode(GrandSlamResponse.stringField(finish, 'tk'));
    final routingInfo = int.parse(
      GrandSlamResponse.stringField(finish, 'X-Apple-I-MD-RINFO'),
    );

    await adi.endProvisioning(cpim.session, ptm, tk);

    // routingInfo is unrecoverable past this point, so persist it now.
    final provisioned = state.copyWith(
      provisioned: true,
      routingInfo: routingInfo,
    );
    await _stateStore.save(provisioned);
    _state = provisioned;
    return provisioned;
  }

  Future<Map<String, Object?>> _postProvisioning(
    String url,
    Map<String, Object?> request,
    AnisetteState state,
  ) async {
    final response = await GrandSlamEndpoints.sendGrandSlamRequest(
      _http,
      method: 'POST',
      url: url,
      operation: 'Anisette provisioning',
      headers: AnisetteHeaders.buildAnisetteProvisioningHeaders(state),
      body: PropertyListSerialization.stringWithPropertyList({
        'Header': <String, Object?>{},
        'Request': request,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AppleError(
        'GrandSlam provisioning request to $url failed '
        '(HTTP ${response.statusCode})',
      );
    }
    return GrandSlamResponse.decodeGrandSlamResponse(response.body);
  }

  static AdiProvisioning _defaultAdiFactory({
    required String adiLibraryDirectory,
    required String provisioningPath,
    required String identifier,
  }) {
    // ADI on Windows is happier with forward-slash provisioning paths
    // (bionic open() stubs translate them); the trailing slash matches
    // Provision's usage.
    final path = provisioningPath.replaceAll(r'\', '/');
    final client = AdiClient.fromDirectory(adiLibraryDirectory)
      ..provisioningPath = path.endsWith('/') ? path : '$path/'
      ..identifier = identifier;
    return _RealAdiProvisioning(client);
  }

  /// ADI's "Android ID": the first 16 lowercase hex characters of the
  /// identity UUID with dashes removed, matching xtool's `XADIProvider`.
  static String _androidId(String localUserUid) =>
      localUserUid.replaceAll('-', '').substring(0, 16).toLowerCase();
}
