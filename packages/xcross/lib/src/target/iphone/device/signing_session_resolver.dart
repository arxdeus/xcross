import 'dart:async';
import 'dart:ffi';

import 'package:apple_developer_kit/host/shared/adi/loader/loader.dart';
import 'package:apple_developer_kit/host/shared/apple_host_services.dart';
import 'package:apple_developer_kit/shared/adi/apk_fetch.dart';
import 'package:apple_developer_kit/shared/appstoreconnect/asc_client.dart';
import 'package:apple_developer_kit/shared/appstoreconnect/asc_config.dart';
import 'package:apple_developer_kit/shared/appstoreconnect/developer_services_client.dart';
import 'package:apple_developer_kit/shared/grandslam/anisette/anisette_data_provider.dart';
import 'package:apple_developer_kit/shared/grandslam/anisette/anisette_provider.dart';
import 'package:apple_developer_kit/shared/grandslam/grandslam_session_store.dart';
import 'package:apple_developer_kit/shared/secure/local_cipher.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/auth/signing_availability.dart';
import 'package:xcross/src/shared/auth/signing_session.dart';
import 'package:xcross/src/shared/device/signing_http_client_factory.dart';
import 'package:xcross/src/shared/errors/errors.dart';

@internal
abstract interface class SigningSessionProvider {
  /// An authenticated session, ready to provision.
  ///
  /// Throws [SigningServiceUnavailable] when Apple cannot be used right now
  /// but the saved credentials name an account whose cached signing material
  /// may still sign the app: no network, an expired Apple ID session, or
  /// [SigningSessionResolver.offlineEnvVar] set.
  Future<SigningSession> resolve();
}

@internal
final class SigningSessionResolver implements SigningSessionProvider {
  const SigningSessionResolver({
    required this.hostServices,
    required this.httpClients,
    required this.createNativeLibraryLoader,
  });
  final AppleHostServices hostServices;
  final SigningHttpClientFactory httpClients;
  final NativeLibraryLoader Function() createNativeLibraryLoader;

  /// Set to any value to skip Apple entirely and sign with the certificate
  /// and profiles an earlier online run cached.
  static const offlineEnvVar = 'XCROSS_OFFLINE';

  /// How long the saved Apple ID session's access check may take before
  /// Apple is treated as unreachable. A captive or dead network can otherwise
  /// hang a run for minutes before the socket gives up.
  static const accessCheckTimeout = Duration(seconds: 20);

  /// Prefer a saved Apple ID session, falling back to App Store Connect
  /// credentials only when no Apple ID session failed — a stored ASC key may
  /// belong to a different team, so a broken Apple session must never silently
  /// switch providers. Throws [XcrossError] listing both failures if neither
  /// works.
  @override
  Future<SigningSession> resolve() async {
    final configPath = AscCredentials.defaultConfigPath(
      hostServices: hostServices,
    );
    final configDirectory = hostServices.host.paths.context.dirname(configPath);

    Object? appleSessionFailure;
    Object? ascFailure;
    Object? unreadableSession;

    GrandSlamSession? session;
    try {
      session = await GrandSlamSessionStore(hostServices: hostServices).load();
    } on LocalCipherError catch (error) {
      // A session sealed on another machine, or one whose key file is gone,
      // carries no team identity at all. Unlike a session that loaded and
      // then failed, it cannot silently point at the wrong team, so falling
      // through to App Store Connect credentials is safe here.
      unreadableSession = error;
    } on Object catch (error) {
      appleSessionFailure = error;
    }

    final offline = hostServices.host.environment.values.containsKey(
      offlineEnvVar,
    );
    if (session != null) {
      final identity = _appleIdentity(session, configDirectory);
      if (offline) throw _offline(identity);
      if (session.isExpired) {
        // Signing itself never needed the session: the certificate and
        // profiles it minted are still on disk and may still be valid.
        const message =
            'Developer Services session has expired. Run xcross auth again.';
        throw SigningServiceUnavailable(
          reason: 'the saved Apple ID session has expired',
          message: message,
          identity: identity,
        );
      }
      try {
        return await _appleIdSession(session, configDirectory);
      } on Object catch (error) {
        if (SigningServiceUnavailable.isConnectivityFailure(error)) {
          throw SigningServiceUnavailable.unreachable(
            error,
            identity: identity,
          );
        }
        appleSessionFailure = error;
      }
    }

    if (appleSessionFailure == null &&
        hostServices.host.fileSystem.file(configPath).existsSync()) {
      try {
        if (offline) {
          final credentials = await AscCredentialsLoader(
            hostServices: hostServices,
          ).load(path: configPath);
          throw _offline(_ascIdentity(credentials, configDirectory));
        }
        return await _ascSession(configPath, configDirectory);
      } on SigningServiceUnavailable {
        rethrow;
      } on Object catch (error) {
        ascFailure = error;
      }
    }

    final unreadable =
        'Apple ID: the saved session cannot be read on this machine, '
        'sign in again to replace it ($unreadableSession)';
    final details = [
      if (appleSessionFailure != null) 'Apple ID: $appleSessionFailure',
      if (unreadableSession != null) unreadable,
      if (ascFailure != null) 'App Store Connect: $ascFailure',
    ];
    throw XcrossError(
      'No usable Apple ID session or App Store Connect credentials found. '
      'Run either:\n'
      '    xcross auth --apple-id <email>\n'
      'or:\n'
      '    xcross auth --issuer-id <id> --key-id <id> '
      '--private-key <path-to-AuthKey_XXXX.p8>'
      '${details.isEmpty ? '' : '\n${details.join('\n')}'}',
    );
  }

  SigningServiceUnavailable _offline(SigningIdentity identity) =>
      SigningServiceUnavailable(
        reason: '$offlineEnvVar is set',
        message: '$offlineEnvVar is set, so xcross will not contact Apple.',
        identity: identity,
      );

  SigningIdentity _appleIdentity(
    GrandSlamSession session,
    String configDirectory,
  ) => SigningIdentity(
    identityId: session.teamId,
    identityDir: SigningSession.identityDirFor(
      configDirectory,
      'developer-services-${session.teamId}',
    ),
  );

  SigningIdentity _ascIdentity(
    AscCredentials credentials,
    String configDirectory,
  ) => SigningIdentity(
    identityId: credentials.issuerId,
    identityDir: SigningSession.identityDirFor(
      configDirectory,
      'appstoreconnect-${credentials.issuerId}',
    ),
  );

  Future<SigningSession> _ascSession(
    String configPath,
    String configDirectory,
  ) async {
    final credentials = await AscCredentialsLoader(
      hostServices: hostServices,
    ).load(path: configPath);
    final identity = _ascIdentity(credentials, configDirectory);
    return SigningSession(
      client: AscClient(credentials, httpClient: httpClients.create()),
      anisette: null,
      identityId: identity.identityId,
      identityDir: identity.identityDir,
    );
  }

  Future<SigningSession> _appleIdSession(
    GrandSlamSession session,
    String configDirectory,
  ) async {
    final anisette = anisetteForSession(
      session,
      hostAbi: hostServices.abi,
      createProvider: (directory) => AnisetteDataProvider(
        directory,
        hostServices: hostServices,
        loader: createNativeLibraryLoader(),
        httpClient: httpClients.create(),
      ),
    );
    final client = DeveloperServicesClient.fromSession(
      session,
      anisette.fetchAnisetteHeaders,
      httpClient: httpClients.create(),
    );
    try {
      // Validate saved auth before any provisioning mutation.
      await client.verifyAccess().timeout(accessCheckTimeout);
    } on Object {
      client.close();
      anisette.close();
      rethrow;
    }
    final identity = _appleIdentity(session, configDirectory);
    return SigningSession(
      client: client,
      anisette: anisette,
      identityId: identity.identityId,
      identityDir: identity.identityDir,
    );
  }

  @visibleForTesting
  static AnisetteProvider anisetteForSession(
    GrandSlamSession session, {
    required Abi hostAbi,
    required AnisetteProvider Function(String directory) createProvider,
  }) {
    final abi = hostAbi;
    if (!AdiLibraryFetcher.supportsAbi(abi)) {
      throw XcrossError(
        'Saved native Apple ID sessions support Linux and macOS x64/ARM64 '
        'and Windows x64/ARM64 (got $abi).',
      );
    }
    final adiDir = session.adiLibraryDirectory;
    if (adiDir == null || adiDir.isEmpty) {
      throw XcrossError(
        'Saved Apple ID session is missing adiLibraryDirectory. '
        'Run xcross auth --apple-id <email> again.',
      );
    }
    return createProvider(adiDir);
  }
}
