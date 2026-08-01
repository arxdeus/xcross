import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:xcross/src/grandslam/anisette/anisette_headers.dart';
import 'package:xcross/src/grandslam/anisette/anisette_provider.dart';
import 'package:xcross/src/grandslam/anisette/anisette_state.dart';
import 'package:xcross/src/grandslam/anisette/grandslam_endpoints.dart';
import 'package:xcross/src/util/apple_http_client.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/process.dart';

class AosKitCoreData {
  const AosKitCoreData({
    required this.oneTimePassword,
    required this.machineIdentifier,
    required this.routingInfo,
  });

  final String oneTimePassword;
  final String machineIdentifier;
  final String routingInfo;
}

/// Calls the bundled x86 bridge which loads the user-installed Apple Windows
/// frameworks. Apple credentials never cross this process boundary; only a
/// fresh machine OTP, machine identifier, and routing value are returned.
class AosKitHelper {
  AosKitHelper({
    Future<String> Function()? locateHelper,
    Future<CapturedProcess> Function(String executable)? runHelper,
  }) : _locateHelper = locateHelper ?? locate,
       _runHelper =
           runHelper ??
           ((executable) => ProcessRunner.run(executable, const []));

  static const _environmentOverride = 'XCROSS_AOSKIT_HELPER_PATH';
  static const _binaryName = 'xcross-aoskit.exe';

  final Future<String> Function() _locateHelper;
  final Future<CapturedProcess> Function(String executable) _runHelper;

  static Future<String> locate() async {
    final override = Platform.environment[_environmentOverride];
    if (override != null && override.isNotEmpty) {
      if (!File(override).existsSync()) {
        throw XcrossError(
          '$_environmentOverride is set to "$override" but no file exists.',
        );
      }
      return override;
    }

    final bundled = p.join(p.dirname(Platform.resolvedExecutable), _binaryName);
    if (File(bundled).existsSync()) return bundled;

    final onPath = await ProcessRunner.which(_binaryName);
    if (onPath != null) return onPath;

    throw XcrossError(
      'Could not find $_binaryName. Place the bundled helper next to xcross, '
      'put it on PATH, or set $_environmentOverride. Apple website editions '
      'of iTunes and iCloud must also be installed on Windows.',
    );
  }

  Future<AosKitCoreData> fetch() async {
    final result = await _runHelper(await _locateHelper());
    if (result.exitCode != 0) {
      final diagnostic = result.stderr.trim();
      throw XcrossError(
        'AOSKit Anisette helper failed (${result.exitCode})'
        '${diagnostic.isEmpty ? '' : ': ${_limit(diagnostic)}'}',
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(result.stdout);
    } on FormatException {
      throw XcrossError('AOSKit helper returned invalid JSON.');
    }
    if (decoded is! Map) {
      throw XcrossError('AOSKit helper returned an invalid document');
    }
    final map = decoded.cast<String, Object?>();
    return AosKitCoreData(
      oneTimePassword: _field(map, 'oneTimePassword'),
      machineIdentifier: _field(map, 'machineIdentifier'),
      routingInfo: _field(map, 'routingInfo'),
    );
  }

  static String _field(Map<String, Object?> map, String name) {
    final value = map[name];
    if (value is! String || value.isEmpty) {
      throw XcrossError('AOSKit helper response is missing "$name"');
    }
    return value;
  }

  static String _limit(String value) =>
      value.length <= 1000 ? value : '${value.substring(0, 1000)}…';
}

class AosKitAnisetteProvider implements AnisetteProvider {
  AosKitAnisetteProvider({
    http.Client? httpClient,
    AnisetteStateStore? stateStore,
    Future<AosKitCoreData> Function()? fetchCoreData,
  }) : _http = httpClient ?? createAppleHttpClient(),
       _stateStore = stateStore ?? AnisetteStateStore(),
       _fetchCoreData = fetchCoreData ?? AosKitHelper().fetch;

  final http.Client _http;
  final AnisetteStateStore _stateStore;
  final Future<AosKitCoreData> Function() _fetchCoreData;

  AnisetteState? _state;
  GrandSlamEndpoints? _endpoints;

  Future<AnisetteState> _loadState() async =>
      _state ??= await _stateStore.load();

  @override
  Future<Map<String, String>> fetchAnisetteHeaders() async {
    final state = await _loadState();
    final core = await _fetchCoreData();
    return buildAnisetteHeaders(
      oneTimePassword: core.oneTimePassword,
      machineIdentifier: core.machineIdentifier,
      routingInfo: core.routingInfo,
      localUserUid: state.localUserUid,
    );
  }

  @override
  Future<GrandSlamEndpoints> resolveGrandSlamEndpoints() async {
    final state = await _loadState();
    return _endpoints ??= await fetchGrandSlamEndpoints(
      _http,
      headers: buildAnisetteLookupHeaders(state),
    );
  }

  @override
  void close() => _http.close();
}
