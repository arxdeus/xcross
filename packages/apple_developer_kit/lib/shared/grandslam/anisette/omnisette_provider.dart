/// Anisette provider backed by a remote Omnisette server
/// (v3 of https://github.com/SideStore/omnisette-server), which synthesizes
/// Mac anisette data. Since 2026-10 Apple's GSA rejects clients whose
/// platform identity does not match their anisette, and it now blocks
/// Android-identifying clients outright (-80046), so the local Android ADI
/// libraries can no longer log in; Mac anisette is the working identity.
///
/// Protocol, ported from xtool's `OmnisetteADIProvider`:
/// - `GET /v3/client_info` returns Mac `client_info` and matching `user_agent`.
/// - `WS  /v3/provisioning_session` runs the one-time device provisioning
///   handshake, message for message, while this provider drives Apple's
///   `midStartProvisioning`/`midFinishProvisioning` plist dance over HTTP.
/// - `POST /v3/get_headers` exchanges the persisted `adi.pb` for a fresh
///   `X-Apple-I-MD`/`X-Apple-I-MD-M` pair per call.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:apple_developer_kit/host/shared/apple_host_services.dart';
import 'package:apple_developer_kit/shared/errors/errors.dart';
import 'package:apple_developer_kit/shared/grandslam/anisette/anisette_provider.dart';
import 'package:apple_developer_kit/shared/grandslam/anisette/anisette_state.dart';
import 'package:apple_developer_kit/shared/grandslam/anisette/grandslam_endpoints.dart';
import 'package:apple_developer_kit/src/shared/grandslam/anisette/anisette_headers.dart';
import 'package:apple_developer_kit/src/shared/grandslam/internal/grandslam_response_decoder.dart';
import 'package:http/http.dart' as http;
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Default public Omnisette server, matching xtool's `OmnisetteADIProvider`.
/// Only used when nothing better is known: `xcross auth` selects the server
/// explicitly via `--anisette-url` (or this environment variable), and the
/// chosen URL is recorded in the saved session and anisette state.
const String kDefaultOmnisetteUrl = 'https://mac-ani.jkcoxson.com';

/// Environment variable selecting the Omnisette server for `xcross auth`
/// (`--anisette-url` wins when both are given), and overriding the recorded
/// URL of a saved Omnisette-based session at signing time.
const String kAnisetteUrlEnvVar = 'XCROSS_ANISETTE_URL';

/// Stored in [AnisetteState.providerId]; a different stored value resets
/// provisioning, since provisioning material never transfers between
/// backends. Matches xtool's provider ID.
const String kOmnisetteProviderId = 'mac-omnisette';

/// One message-oriented WebSocket connection to an Omnisette server.
abstract interface class OmnisetteSocket {
  Future<void> send(String message);

  Future<String> receive();

  void close();
}

/// Opens [OmnisetteSocket]s, injectable so tests can run the provisioning
/// handshake without a live server.
typedef OmnisetteSocketConnector =
    Future<OmnisetteSocket> Function(Uri uri);

Future<OmnisetteSocket> _connectSocket(Uri uri) async {
  final channel = WebSocketChannel.connect(uri);
  await channel.ready;
  return WebSocketChannelOmnisetteSocket(channel);
}

final class WebSocketChannelOmnisetteSocket implements OmnisetteSocket {
  WebSocketChannelOmnisetteSocket(WebSocketChannel channel)
    : _channel = channel,
      _events = StreamIterator<dynamic>(channel.stream);

  final WebSocketChannel _channel;

  // The underlying channel stream is single-subscription; one persistent
  // subscription serves every received handshake message.
  final StreamIterator<dynamic> _events;

  @override
  Future<void> send(String message) async {
    _channel.sink.add(message);
  }

  @override
  Future<String> receive() async {
    if (!await _events.moveNext()) {
      throw const AppleError('Omnisette server closed the connection.');
    }
    final message = _events.current;
    return message is String ? message : utf8.decode(message as List<int>);
  }

  @override
  void close() {
    _channel.sink.close();
  }
}

final class OmnisetteAnisetteProvider implements AnisetteProvider {
  OmnisetteAnisetteProvider({
    required this.hostServices,
    required http.Client httpClient,
    AnisetteStateStore? stateStore,
    String baseUrl = kDefaultOmnisetteUrl,
    OmnisetteSocketConnector? connector,
  }) : _http = httpClient,
       _stateStore =
           stateStore ?? AnisetteStateStore(hostServices: hostServices),
       _baseUrl = baseUrl,
       _connector = connector ?? _connectSocket;

  final AppleHostServices hostServices;
  final String _baseUrl;
  final http.Client _http;
  final AnisetteStateStore _stateStore;
  final OmnisetteSocketConnector _connector;

  AnisetteState? _state;
  GrandSlamEndpoints? _endpoints;
  ({String clientInfo, String userAgent})? _clientInfo;

  @override
  Future<Map<String, String>> fetchAnisetteHeaders() async {
    final state = await _ensureProvisioned(await _loadState());
    final otp = await _requestOtp(state);
    final clientInfo = await _fetchClientInfo();
    return AnisetteHeaders.buildAnisetteHeaders(
      oneTimePassword: otp.oneTimePassword,
      machineIdentifier: otp.machineIdentifier,
      routingInfo: '${otp.routingInfo ?? state.routingInfo}',
      localUserUid: state.localUserUid,
      localeName: hostServices.localeName,
      clientInfo: clientInfo.clientInfo,
      userAgent: clientInfo.userAgent,
    );
  }

  @override
  Future<GrandSlamEndpoints> resolveGrandSlamEndpoints() async {
    final clientInfo = await _fetchClientInfo();
    return _endpoints ??= await GrandSlamEndpoints.fetchGrandSlamEndpoints(
      _http,
      headers: AnisetteHeaders.buildAnisetteLookupHeaders(
        await _loadState(),
        localeName: hostServices.localeName,
        clientInfo: clientInfo.clientInfo,
        userAgent: clientInfo.userAgent,
      ),
    );
  }

  @override
  void close() => _http.close();

  Future<AnisetteState> _loadState() async {
    final loaded = _state ??= await _stateStore.load();
    // A state provisioned against a different server is reset too: its
    // adi.pb is meaningless to this server. A null anisetteServer can only
    // be a state this provider saved against the default URL before the
    // URL started being recorded.
    final sameServer =
        loaded.anisetteServer == _baseUrl ||
        (loaded.anisetteServer == null && _baseUrl == kDefaultOmnisetteUrl);
    if (loaded.providerId == kOmnisetteProviderId && sameServer) {
      return loaded;
    }
    final reset = AnisetteState(
      localUserUid: loaded.localUserUid,
      providerId: kOmnisetteProviderId,
      anisetteServer: _baseUrl,
    );
    await _stateStore.save(reset);
    _state = reset;
    return reset;
  }

  Future<AnisetteState> _ensureProvisioned(AnisetteState state) async {
    if (state.provisioned &&
        state.routingInfo != null &&
        state.adiPb != null) {
      return state;
    }

    final endpoints = await resolveGrandSlamEndpoints();
    final start = await _postProvisioning(endpoints.midStartProvisioning, {});
    final spim = base64Decode(GrandSlamResponse.stringField(start, 'spim'));

    final socket = await _connector(_webSocketUri());
    late final int routingInfo;
    late final String adiPb;
    try {
      await _expectMessage(socket, 'GiveIdentifier');
      await _sendJson(socket, {
        'identifier': base64Encode(_identifierBytes(state.localUserUid)),
      });
      await _expectMessage(socket, 'GiveStartProvisioningData');
      await _sendJson(socket, {'spim': base64Encode(spim)});
      final cpimMessage = await _expectMessage(
        socket,
        'GiveEndProvisioningData',
      );
      final cpim = base64Decode(_requiredField(cpimMessage, 'cpim'));

      final finish = await _postProvisioning(
        endpoints.midFinishProvisioning,
        {'cpim': base64Encode(cpim)},
      );
      final ptm = base64Decode(GrandSlamResponse.stringField(finish, 'ptm'));
      final tk = base64Decode(GrandSlamResponse.stringField(finish, 'tk'));
      routingInfo = int.parse(
        GrandSlamResponse.stringField(finish, 'X-Apple-I-MD-RINFO'),
      );

      await _sendJson(socket, {
        'ptm': base64Encode(ptm),
        'tk': base64Encode(tk),
      });
      final success = await _expectMessage(socket, 'ProvisioningSuccess');
      adiPb = _requiredField(success, 'adi_pb');
    } finally {
      socket.close();
    }

    final provisioned = state.copyWith(
      provisioned: true,
      routingInfo: routingInfo,
      adiPb: adiPb,
      anisetteServer: _baseUrl,
    );
    await _stateStore.save(provisioned);
    _state = provisioned;
    return provisioned;
  }

  Future<Map<String, Object?>> _postProvisioning(
    String url,
    Map<String, Object?> request,
  ) async {
    final clientInfo = await _fetchClientInfo();
    final response = await GrandSlamEndpoints.sendGrandSlamRequest(
      _http,
      method: 'POST',
      url: url,
      operation: 'Anisette provisioning',
      headers: AnisetteHeaders.buildAnisetteProvisioningHeaders(
        await _loadState(),
        localeName: hostServices.localeName,
        clientInfo: clientInfo.clientInfo,
      ),
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

  Future<({String machineIdentifier, String oneTimePassword, int? routingInfo})>
  _requestOtp(AnisetteState state) async {
    final response = await _http.post(
      Uri.parse('$_baseUrl/v3/get_headers'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'identifier': base64Encode(_identifierBytes(state.localUserUid)),
        'adi_pb': state.adiPb,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AppleError(
        'Omnisette get_headers failed (HTTP ${response.statusCode})',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException catch (e) {
      throw AppleError('Omnisette get_headers returned non-JSON: $e');
    }
    if (decoded is! Map) {
      throw const AppleError('Omnisette get_headers returned non-object JSON');
    }
    final json = decoded.cast<String, Object?>();
    return (
      machineIdentifier: _requiredField(json, 'X-Apple-I-MD-M'),
      oneTimePassword: _requiredField(json, 'X-Apple-I-MD'),
      routingInfo: int.tryParse('${json['X-Apple-I-MD-RINFO']}'),
    );
  }

  Future<({String clientInfo, String userAgent})> _fetchClientInfo() async {
    final cached = _clientInfo;
    if (cached != null) return cached;
    final response = await _http.get(
      Uri.parse('$_baseUrl/v3/client_info'),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AppleError(
        'Omnisette client_info failed (HTTP ${response.statusCode})',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException catch (e) {
      throw AppleError('Omnisette client_info returned non-JSON: $e');
    }
    if (decoded is! Map) {
      throw const AppleError(
        'Omnisette client_info returned non-object JSON',
      );
    }
    final json = decoded.cast<String, Object?>();
    return _clientInfo = (
      clientInfo: _requiredField(json, 'client_info'),
      userAgent: _requiredField(json, 'user_agent'),
    );
  }

  Uri _webSocketUri() {
    final base = Uri.parse(_baseUrl);
    final scheme = base.scheme == 'https' ? 'wss' : 'ws';
    return Uri.parse('$scheme://${base.authority}/v3/provisioning_session');
  }

  Future<Map<String, Object?>> _expectMessage(
    OmnisetteSocket socket,
    String result,
  ) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(await socket.receive());
    } on FormatException catch (e) {
      throw AppleError('Omnisette server sent non-JSON: $e');
    }
    if (decoded is! Map) {
      throw const AppleError('Omnisette server sent non-object JSON');
    }
    final json = decoded.cast<String, Object?>();
    if (json['result'] != result) {
      throw AppleError(
        'Expected Omnisette message "$result", got "${json['result']}"',
      );
    }
    return json;
  }

  Future<void> _sendJson(
    OmnisetteSocket socket,
    Map<String, Object?> message,
  ) => socket.send(jsonEncode(message));

  static String _requiredField(Map<String, Object?> json, String field) {
    final value = json[field];
    if (value is! String || value.isEmpty) {
      throw AppleError('Omnisette response missing "$field"');
    }
    return value;
  }

  /// The install identity as raw UUID bytes, the identifier Omnisette
  /// expects (xtool sends `userID.rawBytes`).
  static Uint8List _identifierBytes(String localUserUid) {
    final hex = localUserUid.replaceAll('-', '');
    if (hex.length != 32) {
      throw AppleError('Invalid local user UUID "$localUserUid"');
    }
    return Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);
  }
}
