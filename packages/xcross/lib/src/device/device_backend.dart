import 'dart:io';

import 'package:apple_developer_kit/apple_developer_kit.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/device/internal/embedded_extension.dart';
import 'package:xcross/src/device/internal/signed_bundle_identity.dart';
import 'package:xcross/src/device/internal/signing_session.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/flutter/flutter.dart';

/// Resolves, signs, and installs to a device using the native pipeline.
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

  static Future<DeviceBackend> resolve() async => NativeBackend();
}

/// pymobiledevice3 for device discovery/install, with Apple provisioning and
/// in-process signing.
final class NativeBackend implements DeviceBackend {
  NativeBackend([PymdDeviceResolver? resolver])
    : _resolver = resolver ?? PymdDeviceResolver();

  final PymdDeviceResolver _resolver;

  /// Warnings already shown this install.
  ///
  /// Provisioning runs once per App ID (the app plus one per extension), so a
  /// condition that is really a property of the account — App Groups being
  /// unavailable to API keys, say — would otherwise be printed three times in
  /// a row.
  final Set<String> _warned = {};

  void _warnOnce(String message) {
    if (_warned.add(message)) Log.logWarn(message);
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
    final bundleIdentity = SignedBundleIdentity.qualify(
      requested: bundleId,
      signingIdentityId: signing.identityId,
    );
    final profilesDir = p.join(p.dirname(signing.identityDir), 'profiles');
    final outputDir = p.join(profilesDir, bundleIdentity.exact);

    try {
      await _rewriteBundleIdentifier(appOrIpaPath, bundleIdentity.exact);
      if (bundleIdentity.exact != bundleIdentity.requested) {
        Log.logInfo(
          'App ID',
          '${bundleIdentity.requested} ${Log.dim('→')} ${bundleIdentity.exact}',
        );
        // Custom URL schemes are conventionally derived from the bundle id
        // (`ShareMedia-<bundle id>`), and an extension builds the URL it
        // opens from its *own* qualified host id at runtime. Leaving the
        // app's declared scheme on the unqualified id means nothing is
        // registered to handle that URL, so the hand-off back into the app
        // silently does nothing.
        await _rewriteUrlSchemes(
          appOrIpaPath,
          from: bundleIdentity.requested,
          to: bundleIdentity.exact,
        );
      }
      // Embedded extensions must be renamed under the qualified app id and
      // provisioned in their own right before the app can be signed.
      final extensions = await _rewriteExtensionIdentifiers(
        appOrIpaPath,
        hostBundleId: bundleIdentity.requested,
        signedHostBundleId: bundleIdentity.exact,
      );
      // The app and its extensions must share the same App Groups, or the
      // extension has no way to hand data back to the app.
      final declaredGroups = {
        ...AppExtensionEntitlements.appGroupsOf(appOrIpaPath),
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
      final override = Platform.environment['XCROSS_APP_GROUP']?.trim();
      final appGroups = switch (override) {
        final String group when group.isNotEmpty => [group],
        _ => [
          for (final group in declaredGroups)
            ProvisioningIdentifiers.qualifyAppGroup(group, signing.identityId),
        ],
      };
      final identity = await AscProvisioning.provisionDevelopmentIdentity(
        client: signing.client,
        bundleId: bundleIdentity.exact,
        deviceUdids: [udid],
        outputDir: outputDir,
        identityDir: signing.identityDir,
        appGroups: appGroups,
        onProgress: _warnOnce,
      );
      final asset = await SigningAsset.load(
        privateKeyPemPath: identity.privateKeyPemPath,
        certificatePemPath: identity.certificatePemPath,
        provisioningProfilePath: identity.profilePath,
      );
      final extensionAssets = await _provisionExtensions(
        extensions,
        signing: signing,
        udid: udid,
        profilesDir: profilesDir,
        appGroups: appGroups,
      );
      // Trust the profile over our own request. Provisioning may have failed
      // to attach a group (an API key cannot attach one at all), and it may
      // equally have granted a group that was attached by other means under a
      // name we never asked for. Only the profile decides what iOS will
      // accept, so the runtime `AppGroupId` is taken from it.
      final granted = asset.grantedAppGroups;
      if (granted.isNotEmpty) {
        await _rewriteAppGroupId(appOrIpaPath, granted.first);
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
      await Log.logStep(
        'Signing app',
        () => BundleSigner(
          asset,
          extensionAssets: extensionAssets,
        ).signApp(appOrIpaPath),
      );
      final signedInfoPlist = File(p.join(appOrIpaPath, 'Info.plist'));
      bundleIdentity.verifyArtifact(
        signedInfoPlist.existsSync()
            ? InfoPlist.readBundleIdentifier(
                await signedInfoPlist.readAsString(),
              )
            : null,
      );
      await PymdDevices.install(
        appOrIpaPath,
        udid: udid,
        overTunnel: device.source == DeviceSource.tunneld,
      );
      return bundleIdentity.exact;
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
  static Future<SigningSession> _resolveSigningSession() async {
    final configPath = AscCredentials.defaultConfigPath();
    final configDirectory = p.dirname(configPath);

    Object? appleSessionFailure;
    Object? ascFailure;
    Object? unreadableSession;

    GrandSlamSession? session;
    try {
      session = await GrandSlamSessionStore().load();
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

    if (appleSessionFailure == null && File(configPath).existsSync()) {
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

  static Future<SigningSession> _ascSession(
    String configPath,
    String configDirectory,
  ) async {
    final credentials = await AscCredentials.fromFile(configPath);
    return SigningSession(
      client: AscClient(credentials),
      anisette: null,
      identityId: credentials.issuerId,
      identityDir: SigningSession.identityDirFor(
        configDirectory,
        'appstoreconnect-${credentials.issuerId}',
      ),
    );
  }

  static Future<SigningSession> _appleIdSession(
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

  /// Rewrite every embedded `PlugIns/*.appex` identifier so it stays nested
  /// under the qualified host App ID, and return the new identifiers.
  ///
  /// iOS requires an extension's bundle id to be `<app id>.<suffix>`, so
  /// qualifying the app id (`com.x.App` → `XCR-TEAM.com.x.App`) must carry the
  /// extensions along (`XCR-TEAM.com.x.App.Share-Extension`).
  static Future<List<EmbeddedExtension>> _rewriteExtensionIdentifiers(
    String appPath, {
    required String hostBundleId,
    required String signedHostBundleId,
  }) async {
    final plugIns = Directory(p.join(appPath, 'PlugIns'));
    if (!plugIns.existsSync()) return const [];

    final identifiers = <EmbeddedExtension>[];
    for (final entity in plugIns.listSync()) {
      if (entity is! Directory || !entity.path.endsWith('.appex')) continue;
      final plist = File(p.join(entity.path, 'Info.plist'));
      if (!plist.existsSync()) continue;

      final xml = await plist.readAsString();
      final current = InfoPlist.readBundleIdentifier(xml);
      if (current == null) continue;

      // Preserve the suffix the project declared beneath the app id.
      final suffix = current.startsWith('$hostBundleId.')
          ? current.substring(hostBundleId.length)
          : '.${p.basenameWithoutExtension(entity.path)}';
      final signed = '$signedHostBundleId$suffix';

      await plist.writeAsString(InfoPlist.setBundleIdentifier(xml, signed));
      identifiers.add(
        EmbeddedExtension(
          bundleId: signed,
          appGroups: AppExtensionEntitlements.appGroupsOf(entity.path),
        ),
      );
    }
    identifiers.sort((a, b) => a.bundleId.compareTo(b.bundleId));
    return identifiers;
  }

  /// Point the app and every embedded extension at the qualified App Group.
  ///
  /// Plugins such as `receive_sharing_intent` resolve the shared container at
  /// runtime from the `AppGroupId` Info.plist key, so a qualified group that
  /// is only written into the entitlements would leave both sides looking at
  /// a container neither is entitled to.
  static Future<void> _rewriteAppGroupId(
    String appPath,
    String appGroup,
  ) async {
    final plists = <File>[
      File(p.join(appPath, 'Info.plist')),
      ...?_plugInsPlists(appPath),
    ];
    for (final plist in plists) {
      if (!plist.existsSync()) continue;
      final xml = await plist.readAsString();
      if (!xml.contains('<key>AppGroupId</key>')) continue;
      await plist.writeAsString(
        InfoPlist.setPlistString(xml, 'AppGroupId', appGroup),
      );
    }
  }

  static Iterable<File>? _plugInsPlists(String appPath) {
    final plugIns = Directory(p.join(appPath, 'PlugIns'));
    if (!plugIns.existsSync()) return null;
    return [
      for (final entity in plugIns.listSync())
        if (entity is Directory && entity.path.endsWith('.appex'))
          File(p.join(entity.path, 'Info.plist')),
    ];
  }

  /// Provision a development identity per embedded app extension.
  ///
  /// Each extension is a separate App ID on the portal, so it gets its own
  /// profile. Free Apple developer accounts cap App IDs, hence the explicit
  /// hint when the portal refuses one.
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
      Log.logInfo('Extension', extensionBundleId);
      try {
        final identity = await AscProvisioning.provisionDevelopmentIdentity(
          client: signing.client,
          bundleId: extensionBundleId,
          deviceUdids: [udid],
          outputDir: p.join(profilesDir, extensionBundleId),
          identityDir: signing.identityDir,
          appGroups: appGroups,
          onProgress: _warnOnce,
        );
        assets[extensionBundleId] = await SigningAsset.load(
          privateKeyPemPath: identity.privateKeyPemPath,
          certificatePemPath: identity.certificatePemPath,
          provisioningProfilePath: identity.profilePath,
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

  /// Re-point `CFBundleURLSchemes` entries that embed the unqualified bundle
  /// id at the qualified one.
  ///
  /// Only schemes containing [from] are touched, so unrelated schemes (OAuth
  /// callbacks, `fb<app-id>`, deep links) are left exactly as declared.
  static Future<void> _rewriteUrlSchemes(
    String appPath, {
    required String from,
    required String to,
  }) async {
    final plist = File(p.join(appPath, 'Info.plist'));
    if (!plist.existsSync()) return;
    final xml = await plist.readAsString();
    final rewritten = InfoPlist.rewriteUrlSchemes(xml, from: from, to: to);
    if (rewritten != xml) await plist.writeAsString(rewritten);
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
