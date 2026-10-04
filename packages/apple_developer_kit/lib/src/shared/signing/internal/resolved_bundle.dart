import 'dart:typed_data';

import 'package:meta/meta.dart';

/// A validated `.app` or nested `.framework` bundle awaiting signing.
@immutable
final class ResolvedBundle {
  const ResolvedBundle(
    this.path,
    this.relativePath,
    this.identifier,
    this.executablePath,
    this.infoPlistBytes, {
    required this.isRoot,
    this.isAppExtension = false,
  });

  final String path;
  final String relativePath;
  final String identifier;
  final String executablePath;
  final Uint8List infoPlistBytes;
  final bool isRoot;

  /// Whether this is an embedded app extension (`PlugIns/<Name>.appex`).
  ///
  /// Unlike a nested `.framework`, an extension is an independently
  /// provisioned bundle: it carries its own `embedded.mobileprovision` and is
  /// signed with its own entitlements rather than inheriting the host app's.
  final bool isAppExtension;
}
