import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xcross/src/appstoreconnect/appstoreconnect.dart';
import 'package:xcross/src/device/pymd_device_resolver.dart';
import 'package:xcross/src/device/pymd_devices.dart';
import 'package:xcross/src/grandslam/anisette/anisette_provider.dart';
import 'package:xcross/src/grandslam/anisette/aoskit_anisette_provider.dart';
import 'package:xcross/src/grandslam/grandslam_session_store.dart';
import 'package:xcross/src/models/device/device.dart';
import 'package:xcross/src/signing/bundle_signer.dart';
import 'package:xcross/src/signing/signing_asset.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';

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

    final configPath = AscCredentials.defaultConfigPath();
    final configDirectory = p.dirname(configPath);
    DevelopmentProvisioningClient? client;
    AnisetteProvider? anisette;
    String? outputDir;
    String? identityDir;
    Object? appleSessionFailure;
    Object? ascFailure;

    GrandSlamSession? session;
    try {
      session = await GrandSlamSessionStore().load();
    } on Object catch (error) {
      appleSessionFailure = error;
    }

    if (session != null && !session.isExpired) {
      if (!Platform.isWindows) {
        appleSessionFailure = XcrossError(
          'Saved native Apple ID sessions are currently supported on Windows.',
        );
      } else {
        final candidateAnisette = AosKitAnisetteProvider();
        final candidateClient = DeveloperServicesClient.fromSession(
          session,
          candidateAnisette.fetchAnisetteHeaders,
        );
        try {
          // Validate saved auth before any provisioning mutation. Never
          // silently switch a configured Apple session to another provider:
          // the stored ASC key may belong to a different team.
          await candidateClient.verifyAccess();
          final providerRoot = p.join(
            configDirectory,
            'signing',
            'developer-services-${session.teamId}',
          );
          client = candidateClient;
          anisette = candidateAnisette;
          identityDir = p.join(providerRoot, 'identity');
          outputDir = p.join(providerRoot, 'profiles', bundleId);
        } on Object catch (error) {
          appleSessionFailure = error;
          candidateClient.close();
          candidateAnisette.close();
        }
      }
    } else if (session?.isExpired == true) {
      appleSessionFailure = XcrossError(
        'Developer Services session has expired. Run xcross auth again.',
      );
    }

    if (client == null &&
        appleSessionFailure == null &&
        File(configPath).existsSync()) {
      try {
        final credentials = await AscCredentials.fromFile(configPath);
        final providerRoot = p.join(
          configDirectory,
          'signing',
          'appstoreconnect-${credentials.issuerId}',
        );
        client = AscClient(credentials);
        identityDir = p.join(providerRoot, 'identity');
        outputDir = p.join(providerRoot, 'profiles', bundleId);
      } on Object catch (error) {
        ascFailure = error;
      }
    }

    if (client == null || outputDir == null || identityDir == null) {
      final details = [
        if (appleSessionFailure != null) 'Apple ID: $appleSessionFailure',
        if (ascFailure != null) 'App Store Connect: $ascFailure',
      ];
      final failureDetails = details.isEmpty ? '' : '\n${details.join('\n')}';
      throw XcrossError(
        'No usable Apple ID session or App Store Connect credentials found. '
        'Run either:\n'
        '    xcross auth --apple-id <email>\n'
        'or:\n'
        '    xcross auth --issuer-id <id> --key-id <id> '
        '--private-key <path-to-AuthKey_XXXX.p8>$failureDetails',
      );
    }

    try {
      final identity = await provisionDevelopmentIdentity(
        client: client,
        bundleId: bundleId,
        deviceUdids: [udid],
        outputDir: outputDir,
        identityDir: identityDir,
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
      client.close();
      anisette?.close();
    }
  }
}
