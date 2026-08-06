import 'dart:io';

import 'package:meta/meta.dart';

/// One filesystem entry found while walking a bundle tree.
@immutable
final class BundleEntry {
  const BundleEntry(this.path, this.relativePath, this.type);

  final String path;
  final String relativePath;
  final FileSystemEntityType type;
}
