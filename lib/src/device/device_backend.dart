import 'dart:io';

import 'package:apple_developer_kit/apple_developer_kit.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/util/errors.dart';
import 'package:xcross_flutter/xcross_flutter.dart';

/// An authenticated provisioning client plus the on-disk locations derived
/// from whichever identity (Apple ID team or ASC issuer) it authenticated as.
typedef _SigningSession = ({
  DevelopmentProvisioningClient client,
  AnisetteProvider? anisette,
  String identityId,
  String identityDir,
});

/// Resolves, signs, and installs to a device using the native pipeline.
abstract class DeviceBackend {
  Future<Device> resolveDevice({
    required DeviceSearchMode mode,
    String? selector,
  });

  Future<void> install(
    String appOrIpaPath, {
    required String udid,
    required DeviceSearchMode mode,
    required String bundleId,
  });

  static Future<DeviceBackend> resolve() async => NativeBackend();
}

/// pymobiledevice3 for device discovery/install, with Apple provisioning and
/// in-process signing.
class NativeBackend implements DeviceBackend {
  NativeBackend([PymdDeviceResolver? resolver])
    : _resolver = resolver ?? PymdDeviceResolver();

  final PymdDeviceResolver _resolver;

  @override
  Future<Device> resolveDevice({
    required DeviceSearchMode mode,
    String? selector,
  }) => _resolver.resolveDevice(selector: selector, mode: mode);

  @override
  Future<void> install(
    String appOrIpaPath, {
    required String udid,
    required DeviceSearchMode mode,
    required String bundleId,
  }) async {
    if (!appOrIpaPath.endsWith('.app') ||
        !Directory(appOrIpaPath).existsSync()) {
      throw XcrossError(
        'The in-process signer currently supports xcross-generated .app '
        'directories only; "$appOrIpaPath" is not an existing .app directory.',
      );
    }

    final signing = await _resolveSigningSession();
    // xtool-style: qualify with XCR-<identity> so two accounts can share a
    // project bundle id without racing on a globally unique App ID.
    final signedBundleId = ProvisioningIdentifiers.qualify(
      bundleId,
      signing.identityId,
    );
    final outputDir = p.join(
      p.dirname(signing.identityDir),
      'profiles',
      signedBundleId,
    );

    try {
      await _rewriteBundleIdentifier(appOrIpaPath, signedBundleId);
      if (signedBundleId != bundleId) {
        Log.logInfo(
          'App ID',
          '$bundleId ${Log.ansi.subtle('→')} $signedBundleId',
        );
      }
      final identity = await AscProvisioning.provisionDevelopmentIdentity(
        client: signing.client,
        bundleId: signedBundleId,
        deviceUdids: [udid],
        outputDir: outputDir,
        identityDir: signing.identityDir,
        onProgress: Log.logWarn,
      );
      final asset = await SigningAsset.load(
        privateKeyPemPath: identity.privateKeyPemPath,
        certificatePemPath: identity.certificatePemPath,
        provisioningProfilePath: identity.profilePath,
      );
      await Log.logStep(
        'Signing app',
        () => BundleSigner(asset).signApp(appOrIpaPath),
      );
      await PymdDevices.install(appOrIpaPath, udid: udid);
    } finally {
      signing.client.close();
      signing.anisette?.close();
    }
  }

  /// Prefer a saved Apple ID session, falling back to App Store Connect
  /// credentials only when no Apple ID session failed — a stored ASC key may
  /// belong to a different team, so a broken Apple session must never silently
  /// switch providers. Throws [XcrossError] listing both failures if neither
  /// works.
  static Future<_SigningSession> _resolveSigningSession() async {
    final configPath = AscCredentials.defaultConfigPath();
    final configDirectory = p.dirname(configPath);

    Object? appleSessionFailure;
    Object? ascFailure;

    GrandSlamSession? session;
    try {
      session = await GrandSlamSessionStore().load();
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

    if (appleSessionFailure == null && File(configPath).existsSync()) {
      try {
        return await _ascSession(configPath, configDirectory);
      } on Object catch (error) {
        ascFailure = error;
      }
    }

    final details = [
      if (appleSessionFailure != null) 'Apple ID: $appleSessionFailure',
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

  static Future<_SigningSession> _ascSession(
    String configPath,
    String configDirectory,
  ) async {
    final credentials = await AscCredentials.fromFile(configPath);
    return (
      client: AscClient(credentials),
      anisette: null,
      identityId: credentials.issuerId,
      identityDir: p.join(
        configDirectory,
        'signing',
        'appstoreconnect-${credentials.issuerId}',
        'identity',
      ),
    );
  }

  static Future<_SigningSession> _appleIdSession(
    GrandSlamSession session,
    String configDirectory,
  ) async {
    final anisette = _anisetteForSession(session);
    final client = DeveloperServicesClient.fromSession(
      session,
      anisette.fetchAnisetteHeaders,
    );
    try {
      // Validate saved auth before any provisioning mutation.
      await client.verifyAccess();
    } on Object {
      client.close();
      anisette.close();
      rethrow;
    }
    return (
      client: client,
      anisette: anisette,
      identityId: session.teamId,
      identityDir: p.join(
        configDirectory,
        'signing',
        'developer-services-${session.teamId}',
        'identity',
      ),
    );
  }

  /// Point the built `.app` at the qualified App ID before codesign.
  static Future<void> _rewriteBundleIdentifier(
    String appPath,
    String bundleId,
  ) async {
    final plist = File(p.join(appPath, 'Info.plist'));
    if (!plist.existsSync()) {
      throw XcrossError('Missing Info.plist in "$appPath"');
    }
    final updated = InfoPlist.setBundleIdentifier(
      await plist.readAsString(),
      bundleId,
    );
    await plist.writeAsString(updated);
  }

  static AnisetteProvider _anisetteForSession(GrandSlamSession session) {
    if (Platform.isWindows || Platform.isLinux) {
      final adiDir = session.adiLibraryDirectory;
      if (adiDir == null || adiDir.isEmpty) {
        throw XcrossError(
          'Saved Apple ID session is missing adiLibraryDirectory. '
          'Run xcross auth --apple-id <email> again.',
        );
      }
      return AnisetteDataProvider(adiDir);
    }
    throw XcrossError(
      'Saved native Apple ID sessions are supported on Linux and Windows.',
    );
  }
}
