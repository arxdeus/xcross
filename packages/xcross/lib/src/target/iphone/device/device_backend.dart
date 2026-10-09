import 'package:apple_developer_kit/host/shared/adi/loader/loader.dart';
import 'package:apple_developer_kit/host/shared/apple_host_services.dart';
import 'package:apple_developer_kit/shared/appstoreconnect/appstoreconnect.dart';
import 'package:apple_developer_kit/shared/appstoreconnect/provisioning_identifiers.dart';
import 'package:apple_developer_kit/shared/signing/bundle_signer.dart';
import 'package:apple_developer_kit/shared/signing/signing_asset.dart';
import 'package:dart_mobile_device/shared/device/models/device.dart';
import 'package:dart_mobile_device/target/iphone/device/pymd/pymd.dart';
import 'package:dart_mobile_device/target/iphone/device/pymd/pymd_device_resolver.dart';
import 'package:dart_mobile_device/target/iphone/device/pymd/pymd_devices.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/artifact/app_capabilities.dart';
import 'package:xcross/src/shared/artifact/app_entitlements.dart';
import 'package:xcross/src/shared/artifact/embedded_extension.dart';
import 'package:xcross/src/shared/artifact/plist_mutations.dart';
import 'package:xcross/src/shared/auth/signing_session.dart';
import 'package:xcross/src/shared/cli/command_prompt.dart';
import 'package:xcross/src/shared/device/signing_http_client_factory.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/target/iphone/device/internal/bundle_identity_resolver.dart';
import 'package:xcross/src/target/iphone/device/internal/signed_bundle_identity.dart';
import 'package:xcross/src/target/iphone/device/signed_bundle_preparer.dart';
import 'package:xcross/src/target/iphone/device/signing_session_resolver.dart';

/// Resolves, signs, and installs to a device using the native pipeline.
@internal
abstract interface class DeviceBackend {
  Future<Device> resolveDevice({
    required DeviceSearchMode mode,
    String? selector,
  });

  /// Installs and returns the bundle id the app actually carries on the
  /// device — the team-qualified (`XCR-<identity>.<id>`) one when the signer
  /// rewrote it. The launch that follows must use exactly this id: a device
  /// can hold several team-qualified builds of the same app, and resolving
  /// the base id by suffix can land on a stale one from another identity.
  Future<String> install(
    String appOrIpaPath, {
    required Device device,
    required String bundleId,
  });

  static Future<DeviceBackend> resolve(
    Pymd pymd, {
    required AppleHostServices hostServices,
    required NativeLibraryLoader Function() createNativeLibraryLoader,
    required SigningHttpClientFactory httpClients,
    CommandPrompt? prompt,
  }) async => NativeBackend(
    pymd,
    hostServices: hostServices,
    createNativeLibraryLoader: createNativeLibraryLoader,
    httpClients: httpClients,
    prompt: prompt,
  );
}

/// pymobiledevice3 for device discovery/install, with Apple provisioning and
/// in-process signing.
@internal
final class NativeBackend implements DeviceBackend {
  NativeBackend(
    this.pymd, {
    required this.hostServices,
    required this.createNativeLibraryLoader,
    required this.httpClients,
    this.prompt,
    PymdDeviceResolver? resolver,
    SigningSessionProvider? signingSessions,
  }) : _signingSessions =
           signingSessions ??
           SigningSessionResolver(
             hostServices: hostServices,
             createNativeLibraryLoader: createNativeLibraryLoader,
             httpClients: httpClients,
           ),
       _resolver = resolver ?? PymdDeviceResolver(pymd) {
    if (!identical(pymd.runner.host, hostServices.host)) {
      throw ArgumentError(
        'device runner and Apple services must share one host',
      );
    }
  }

  final Pymd pymd;

  /// Asks which App ID a first build registers; `null` never asks.
  final CommandPrompt? prompt;
  late final AppCapabilities _capabilities = AppCapabilities(
    fileSystem: pymd.runner.host.fileSystem,
    paths: pymd.runner.host.paths,
  );
  late final AppEntitlements _entitlements = AppEntitlements(
    fileSystem: pymd.runner.host.fileSystem,
    paths: pymd.runner.host.paths,
  );
  late final SignedBundlePreparer _bundlePreparer = SignedBundlePreparer(
    fileSystem: pymd.runner.host.fileSystem,
    paths: pymd.runner.host.paths,
  );
  final AppleHostServices hostServices;
  final SigningHttpClientFactory httpClients;
  final NativeLibraryLoader Function() createNativeLibraryLoader;

  final PymdDeviceResolver _resolver;
  final SigningSessionProvider _signingSessions;

  /// Warnings already shown this install.
  ///
  /// Provisioning runs once per App ID (the app plus one per extension), so a
  /// condition that is really a property of the account — App Groups being
  /// unavailable to API keys, say — would otherwise be printed three times in
  /// a row.
  final Set<String> _warned = {};

  void _warnOnce(String message) {
    if (_warned.add(message)) pymd.runner.log.logWarn(message);
  }

  @override
  Future<Device> resolveDevice({
    required DeviceSearchMode mode,
    String? selector,
  }) => _resolver.resolveDevice(selector: selector, mode: mode);

  @override
  Future<String> install(
    String appOrIpaPath, {
    required Device device,
    required String bundleId,
  }) async {
    final udid = device.udid;
    final isAppDirectory =
        appOrIpaPath.endsWith('.app') &&
        pymd.runner.host.fileSystem.directory(appOrIpaPath).existsSync();
    if (!isAppDirectory) {
      throw XcrossError(
        'The in-process signer currently supports xcross-generated .app '
        'directories only; "$appOrIpaPath" is not an existing .app directory.',
      );
    }

    _bundlePreparer.validateContainment(appOrIpaPath);
    final signing = await _signingSessions.resolve();
    try {
      final bundleIdentity = await _qualifyBundleIdentity(signing, bundleId);
      final profilesDir = pymd.runner.host.paths.context.join(
        pymd.runner.host.paths.context.dirname(signing.identityDir),
        'profiles',
      );
      final outputDir = pymd.runner.host.paths.context.join(
        profilesDir,
        bundleIdentity.exact,
      );

      await _rewriteAppIdentifiers(appOrIpaPath, bundleIdentity);
      // Embedded extensions must be renamed under the qualified app id and
      // provisioned in their own right before the app can be signed.
      final extensions = await _bundlePreparer.rewriteExtensionIdentifiers(
        appOrIpaPath,
        hostBundleId: bundleIdentity.requested,
        signedHostBundleId: bundleIdentity.exact,
      );
      final appGroups = _resolveAppGroups(appOrIpaPath, extensions, signing);
      final asset = await _provisionApp(
        appOrIpaPath,
        signing: signing,
        bundleId: bundleIdentity.exact,
        udid: udid,
        outputDir: outputDir,
        appGroups: appGroups,
      );
      final extensionAssets = await _provisionExtensions(
        extensions,
        signing: signing,
        udid: udid,
        profilesDir: profilesDir,
        appGroups: appGroups,
      );
      await _applyGrantedAppGroups(
        appOrIpaPath,
        asset: asset,
        extensionAssets: extensionAssets,
        appGroups: appGroups,
      );
      await _stripPrivateKeys(appOrIpaPath, extensions);
      await pymd.runner.log.logStep(
        'Signing app',
        () => BundleSigner(
          asset,
          hostServices: hostServices,
          extensionAssets: extensionAssets,
        ).signApp(appOrIpaPath),
      );
      await _verifySignedBundleId(appOrIpaPath, bundleIdentity);
      await PymdDevices(pymd).install(
        appOrIpaPath,
        udid: udid,
        overTunnel: device.source == DeviceSource.tunneld,
      );
      return bundleIdentity.exact;
    } finally {
      try {
        signing.client.close();
      } finally {
        signing.anisette?.close();
      }
    }
  }

  Future<SignedBundleIdentity> _qualifyBundleIdentity(
    SigningSession signing,
    String bundleId,
  ) =>
      // xtool-style: qualify with XCR-<identity> so two accounts can share a
      // project bundle id without racing for a globally unique App ID. An App
      // ID this team already owns is used as it is: qualifying it makes the
      // app a different App ID, and everything bound to the real one stops
      // working - an Apple identity token carries the bundle id as its `aud`,
      // passkeys and `ASWebAuthenticationSession.Callback.https` are bound
      // through the App ID's AASA `webcredentials` entry, and push, Sign in
      // with Apple and Associated Domains are all provisioned per App ID. On
      // the app's first build, when neither exists, the user picks.
      BundleIdentityResolver(
        client: signing.client,
        log: pymd.runner.log,
        prompt: prompt,
        environment: pymd.runner.effectiveEnvironment,
      ).resolve(requested: bundleId, signingIdentityId: signing.identityId);

  Future<void> _rewriteAppIdentifiers(
    String appOrIpaPath,
    SignedBundleIdentity bundleIdentity,
  ) async {
    await _bundlePreparer.rewriteBundleIdentifier(
      appOrIpaPath,
      bundleIdentity.exact,
    );
    if (bundleIdentity.exact != bundleIdentity.requested) {
      pymd.runner.log.logInfo(
        'App ID',
        '${bundleIdentity.requested} ${pymd.runner.log.dim('→')} ${bundleIdentity.exact}',
      );
      // Custom URL schemes are conventionally derived from the bundle id
      // (`ShareMedia-<bundle id>`), and an extension builds the URL it
      // opens from its *own* qualified host id at runtime. Leaving the
      // app's declared scheme on the unqualified id means nothing is
      // registered to handle that URL, so the hand-off back into the app
      // silently does nothing.
      await _bundlePreparer.rewriteUrlSchemes(
        appOrIpaPath,
        from: bundleIdentity.requested,
        to: bundleIdentity.exact,
      );
    }
  }

  List<String> _resolveAppGroups(
    String appOrIpaPath,
    List<EmbeddedExtension> extensions,
    SigningSession signing,
  ) {
    // The app and its extensions must share the same App Groups, or the
    // extension has no way to hand data back to the app.
    final declaredGroups = {
      ...AppExtensionEntitlements(
        fileSystem: pymd.runner.host.fileSystem,
        paths: pymd.runner.host.paths,
      ).appGroupsOf(appOrIpaPath),
      for (final extension in extensions) ...extension.appGroups,
    }.toList()..sort();
    // App Group ids are globally unique across all developers, so a
    // project's literal `group.com.example.Shared` is usually already
    // registered to somebody else and xcross qualifies it per account.
    //
    // XCROSS_APP_GROUP opts out of that. It names a group the account
    // already owns, which is the only way an App Store Connect API key can
    // get one: keys cannot create or attach App Groups, but they do issue
    // profiles that carry a group attached by other means. Set it to a
    // group you added to these App IDs in Xcode or at developer.apple.com
    // and the whole share flow works on an API key.
    final override = pymd.runner.effectiveEnvironment['XCROSS_APP_GROUP']
        ?.trim();
    return switch (override) {
      final String group when group.isNotEmpty => [group],
      _ => [
        for (final group in declaredGroups)
          ProvisioningIdentifiers.qualifyAppGroup(group, signing.identityId),
      ],
    };
  }

  Future<SigningAsset> _provisionApp(
    String appOrIpaPath, {
    required SigningSession signing,
    required String bundleId,
    required String udid,
    required String outputDir,
    required List<String> appGroups,
  }) async {
    final identity =
        await AscProvisioning(
          hostServices: hostServices,
          client: signing.client,
        ).provisionDevelopmentIdentity(
          bundleId: bundleId,
          deviceUdids: [udid],
          outputDir: outputDir,
          identityDir: signing.identityDir,
          appGroups: appGroups,
          // Recorded by the assembler from the project's entitlements; a profile
          // only grants what the App ID has switched on.
          capabilities: _capabilities.of(appOrIpaPath).toSet(),
          onProgress: _warnOnce,
        );
    final asset = await SigningAssetLoader(hostServices: hostServices).load(
      privateKeyPemPath: identity.privateKeyPemPath,
      certificatePemPath: identity.certificatePemPath,
      provisioningProfilePath: identity.profilePath,
      // The profile's generic values lose to what the app declares, or the
      // app ends up asking iOS for `associated-domains: *`.
      declaredEntitlements: _entitlements.of(appOrIpaPath),
    );
    return asset;
  }

  Future<void> _applyGrantedAppGroups(
    String appOrIpaPath, {
    required SigningAsset asset,
    required Map<String, SigningAsset> extensionAssets,
    required List<String> appGroups,
  }) async {
    // Trust the profile over our own request. Provisioning may have failed
    // to attach a group (an API key cannot attach one at all), and it may
    // equally have granted a group that was attached by other means under a
    // name we never asked for. Only the profile decides what iOS will
    // accept, so the runtime `AppGroupId` is taken from it.
    final granted = asset.grantedAppGroups;
    if (granted.isNotEmpty) {
      await _bundlePreparer.rewriteAppGroupId(appOrIpaPath, granted.first);
      // Each extension is signed with its own profile, so a group the app
      // has but an extension lacks would silently break the hand-off at
      // runtime rather than at install time.
      for (final entry in extensionAssets.entries) {
        if (entry.value.grantedAppGroups.contains(granted.first)) continue;
        _warnOnce(
          '"${entry.key}" is not provisioned for ${granted.first}, so it '
          'cannot share data with the app. Re-run to re-issue its profile, '
          'or add the group to that App ID at developer.apple.com.',
        );
      }
    } else if (appGroups.isNotEmpty) {
      _warnOnce(
        'No App Group is provisioned, so the app and its extensions cannot '
        'share data. Everything else still installs and runs.\n'
        '  Apple exposes no App Groups API to App Store Connect keys. Add a '
        'group to these App IDs in Xcode or at developer.apple.com, then '
        'set XCROSS_APP_GROUP=<group.your.id> to use it, or sign in with '
        '`xcross auth --apple-id <email>` and xcross will do it all for '
        'you.',
      );
    }
  }

  Future<void> _stripPrivateKeys(
    String appOrIpaPath,
    List<EmbeddedExtension> extensions,
  ) async {
    // The assembler's private hand-off keys have served their purpose by now
    // (capabilities were provisioned, entitlements folded into `asset`), and
    // they are not iOS keys. Strip them before the signature seals the plist,
    // or every Compose app ships with them.
    await _bundlePreparer.stripPrivateKeys(appOrIpaPath);
    for (final extension in extensions) {
      if (extension.path case final String path) {
        await _bundlePreparer.stripPrivateKeys(path);
      }
    }
  }

  Future<void> _verifySignedBundleId(
    String appOrIpaPath,
    SignedBundleIdentity bundleIdentity,
  ) async {
    final signedInfoPlist = pymd.runner.host.fileSystem.file(
      pymd.runner.host.paths.context.join(appOrIpaPath, 'Info.plist'),
    );
    final signedBundleId = signedInfoPlist.existsSync()
        ? PlistMutations.readBundleIdentifier(
            await signedInfoPlist.readAsString(),
          )
        : null;
    bundleIdentity.verifyArtifact(signedBundleId);
  }

  Future<Map<String, SigningAsset>> _provisionExtensions(
    List<EmbeddedExtension> extensions, {
    required SigningSession signing,
    required String udid,
    required String profilesDir,
    required List<String> appGroups,
  }) async {
    if (extensions.isEmpty) return const {};

    final assets = <String, SigningAsset>{};
    for (final extension in extensions) {
      final extensionBundleId = extension.bundleId;
      pymd.runner.log.logInfo('Extension', extensionBundleId);
      try {
        final identity =
            await AscProvisioning(
              hostServices: hostServices,
              client: signing.client,
            ).provisionDevelopmentIdentity(
              bundleId: extensionBundleId,
              deviceUdids: [udid],
              outputDir: pymd.runner.host.paths.context.join(
                profilesDir,
                extensionBundleId,
              ),
              identityDir: signing.identityDir,
              appGroups: appGroups,
              capabilities: {
                if (extension.path case final String path)
                  ..._capabilities.of(path),
              },
              onProgress: _warnOnce,
            );
        assets[extensionBundleId] =
            await SigningAssetLoader(hostServices: hostServices).load(
              privateKeyPemPath: identity.privateKeyPemPath,
              certificatePemPath: identity.certificatePemPath,
              provisioningProfilePath: identity.profilePath,
              declaredEntitlements: switch (extension.path) {
                final String path => _entitlements.of(path),
                null => const {},
              },
            );
      } on Object catch (error) {
        throw XcrossError(
          'Could not provision the app extension "$extensionBundleId": $error\n'
          'Free Apple developer accounts allow only 10 App IDs per 7 days, '
          'and each extension needs its own.',
        );
      }
    }
    return assets;
  }

  /// Point the built `.app` at the qualified App ID before codesign.
}
