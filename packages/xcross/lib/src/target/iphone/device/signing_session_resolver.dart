import 'dart:ffi';

import 'package:apple_developer_kit/apple_developer_kit_shared.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/device/internal/signing_session.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/shared/device/signing_http_client_factory.dart';

abstract interface class SigningSessionProvider {
  Future<SigningSession> resolve();
}

final class SigningSessionResolver implements SigningSessionProvider {
  const SigningSessionResolver({
    required this.hostServices,
    required this.httpClients,
    required this.createNativeLibraryLoader,
  });
  final AppleHostServices hostServices;
  final SigningHttpClientFactory httpClients;
  final NativeLibraryLoader Function() createNativeLibraryLoader;

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

    if (session != null && !session.isExpired) {
      try {
        return await _appleIdSession(session, configDirectory);
      } on Object catch (error) {
        appleSessionFailure = error;
      }
    } else if (session?.isExpired == true) {
      appleSessionFailure = XcrossError(
        'Developer Services session has expired. Run xcross auth again.',
      );
    }

    if (appleSessionFailure == null &&
        hostServices.host.fileSystem.file(configPath).existsSync()) {
      try {
        return await _ascSession(configPath, configDirectory);
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

  Future<SigningSession> _ascSession(
    String configPath,
    String configDirectory,
  ) async {
    final credentials = await AscCredentialsLoader(
      hostServices: hostServices,
    ).load(path: configPath);
    return SigningSession(
      client: AscClient(credentials, httpClient: httpClients.create()),
      anisette: null,
      identityId: credentials.issuerId,
      identityDir: SigningSession.identityDirFor(
        configDirectory,
        'appstoreconnect-${credentials.issuerId}',
      ),
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
      await client.verifyAccess();
    } on Object {
      client.close();
      anisette.close();
      rethrow;
    }
    return SigningSession(
      client: client,
      anisette: anisette,
      identityId: session.teamId,
      identityDir: SigningSession.identityDirFor(
        configDirectory,
        'developer-services-${session.teamId}',
      ),
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
        'and Windows x64 (got $abi).',
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
