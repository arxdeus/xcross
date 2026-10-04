import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:xcross/src/shared/artifact/app_capabilities.dart';
import 'package:xcross/src/shared/artifact/app_entitlements.dart';
import 'package:xcross/src/shared/artifact/embedded_extension.dart';
import 'package:xcross/src/shared/artifact/plist_mutations.dart';
import 'package:xcross/src/shared/errors/errors.dart';

@internal
final class SignedBundlePreparer {
  const SignedBundlePreparer({required this.fileSystem, required this.paths});
  final HostFileSystemInterface fileSystem;
  final HostPathsInterface paths;

  void validateContainment(String appPath) {
    final root = fileSystem.directory(appPath);
    if (fileSystem.link(appPath).existsSync() || !root.existsSync()) {
      throw XcrossError('Bundle root must be a real directory: "$appPath"');
    }
    final canonicalRoot = root.resolveSymbolicLinksSync();
    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      if (entity is! Link) continue;
      final relative = paths.context.relative(entity.path, from: appPath);
      final components = paths.context.split(relative);
      if (components.last == 'Info.plist' ||
          components.first == 'PlugIns' &&
              (components.length == 1 || components.last.endsWith('.appex'))) {
        throw XcrossError(
          'Bundle contains a linked mutation target: "${entity.path}"',
        );
      }
      String resolved;
      try {
        resolved = entity.resolveSymbolicLinksSync();
      } on FileSystemException {
        throw XcrossError(
          'Bundle contains an unresolved link: "${entity.path}"',
        );
      }
      if (paths.pathKey(resolved) != paths.pathKey(canonicalRoot) &&
          !paths.context.isWithin(canonicalRoot, resolved)) {
        throw XcrossError('Bundle link escapes its root: "${entity.path}"');
      }
    }
  }

  /// Rewrite every embedded `PlugIns/*.appex` identifier so it stays nested
  /// under the qualified host App ID, and return the new identifiers.
  ///
  /// iOS requires an extension's bundle id to be `<app id>.<suffix>`, so
  /// qualifying the app id (`com.x.App` → `XCR-TEAM.com.x.App`) must carry the
  /// extensions along (`XCR-TEAM.com.x.App.Share-Extension`).
  Future<List<EmbeddedExtension>> rewriteExtensionIdentifiers(
    String appPath, {
    required String hostBundleId,
    required String signedHostBundleId,
  }) async {
    validateContainment(appPath);
    final plugIns = fileSystem.directory(
      paths.context.join(appPath, 'PlugIns'),
    );
    if (!plugIns.existsSync()) return const [];

    final identifiers = <EmbeddedExtension>[];
    for (final entity in plugIns.listSync()) {
      if (entity is! Directory || !entity.path.endsWith('.appex')) continue;
      final plist = fileSystem.file(
        paths.context.join(entity.path, 'Info.plist'),
      );
      if (!plist.existsSync()) continue;

      final xml = await plist.readAsString();
      final current = PlistMutations.readBundleIdentifier(xml);
      if (current == null) continue;

      // Preserve the suffix the project declared beneath the app id.
      final suffix = current.startsWith('$hostBundleId.')
          ? current.substring(hostBundleId.length)
          : '.${paths.context.basenameWithoutExtension(entity.path)}';
      final signed = '$signedHostBundleId$suffix';

      await plist.writeAsString(
        PlistMutations.setBundleIdentifier(xml, signed),
      );
      identifiers.add(
        EmbeddedExtension(
          path: entity.path,
          bundleId: signed,
          appGroups: AppExtensionEntitlements(
            fileSystem: fileSystem,
            paths: paths,
          ).appGroupsOf(entity.path),
        ),
      );
    }
    identifiers.sort((a, b) => a.bundleId.compareTo(b.bundleId));
    return identifiers;
  }

  /// Removes the assembler's private hand-off keys from the app's `Info.plist`.
  ///
  /// [AppCapabilities.infoPlistKey] and [AppEntitlements.infoPlistKey] carry the
  /// project's entitlements from build time to signing time, which is the only
  /// span in which they mean anything. Leaving them in ships the app's declared
  /// entitlements as plain text in a shipped bundle, and puts two keys iOS does
  /// not know in the signed plist.
  ///
  /// Text-level, like the rest of the plist edits here: re-serializing would
  /// rewrite a plist this code did not necessarily write. The result is parsed
  /// before it is written back, because this runs on the shared install path -
  /// a Flutter or prebuilt bundle never has these keys, and a cosmetic cleanup
  /// must never be the reason an app fails to install.
  Future<void> stripPrivateKeys(String appPath) async {
    validateContainment(appPath);
    final plist = fileSystem.file(paths.context.join(appPath, 'Info.plist'));
    if (!plist.existsSync()) return;
    final xml = await plist.readAsString();
    if (!xml.contains(AppCapabilities.infoPlistKey) &&
        !xml.contains(AppEntitlements.infoPlistKey)) {
      return;
    }
    var stripped = xml;
    for (final key in [
      AppCapabilities.infoPlistKey,
      AppEntitlements.infoPlistKey,
    ]) {
      stripped = PlistMutations.removePlistKey(stripped, key);
    }
    if (stripped == xml) return;
    try {
      final reparsed = PropertyListSerialization.propertyListWithString(
        stripped,
      );
      if (reparsed is! Map) return;
    } on Object {
      return;
    }
    await plist.writeAsString(stripped);
  }

  /// Point the app and every embedded extension at the qualified App Group.
  ///
  /// Plugins such as `receive_sharing_intent` resolve the shared container at
  /// runtime from the `AppGroupId` Info.plist key, so a qualified group that
  /// is only written into the entitlements would leave both sides looking at
  /// a container neither is entitled to.
  Future<void> rewriteAppGroupId(String appPath, String appGroup) async {
    validateContainment(appPath);
    final plists = <File>[
      fileSystem.file(paths.context.join(appPath, 'Info.plist')),
      ...?plugInsPlists(appPath),
    ];
    for (final plist in plists) {
      if (!plist.existsSync()) continue;
      final xml = await plist.readAsString();
      if (!xml.contains('<key>AppGroupId</key>')) continue;
      await plist.writeAsString(
        PlistMutations.setPlistString(xml, 'AppGroupId', appGroup),
      );
    }
  }

  Iterable<File>? plugInsPlists(String appPath) {
    validateContainment(appPath);
    final plugIns = fileSystem.directory(
      paths.context.join(appPath, 'PlugIns'),
    );
    if (!plugIns.existsSync()) return null;
    return [
      for (final entity in plugIns.listSync())
        if (entity is Directory && entity.path.endsWith('.appex'))
          fileSystem.file(paths.context.join(entity.path, 'Info.plist')),
    ];
  }

  /// Provision a development identity per embedded app extension.
  ///
  /// Each extension is a separate App ID on the portal, so it gets its own
  /// profile. Free Apple developer accounts cap App IDs, hence the explicit
  /// hint when the portal refuses one.
  Future<void> rewriteBundleIdentifier(String appPath, String bundleId) async {
    validateContainment(appPath);
    final plist = fileSystem.file(paths.context.join(appPath, 'Info.plist'));
    if (!plist.existsSync()) {
      throw XcrossError('Missing Info.plist in "$appPath"');
    }
    final updated = PlistMutations.setBundleIdentifier(
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
  Future<void> rewriteUrlSchemes(
    String appPath, {
    required String from,
    required String to,
  }) async {
    validateContainment(appPath);
    final plist = fileSystem.file(paths.context.join(appPath, 'Info.plist'));
    if (!plist.existsSync()) return;
    final xml = await plist.readAsString();
    final rewritten = PlistMutations.rewriteUrlSchemes(xml, from: from, to: to);
    if (rewritten != xml) await plist.writeAsString(rewritten);
  }
}
