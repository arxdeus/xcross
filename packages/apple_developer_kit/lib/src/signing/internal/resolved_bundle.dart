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
  });

  final String path;
  final String relativePath;
  final String identifier;
  final String executablePath;
  final Uint8List infoPlistBytes;
  final bool isRoot;
}
