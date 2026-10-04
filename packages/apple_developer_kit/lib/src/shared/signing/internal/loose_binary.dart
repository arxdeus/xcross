import 'package:meta/meta.dart';

/// A standalone Mach-O (e.g. a `Frameworks/` dylib) not owned by any bundle.
@immutable
final class LooseBinary {
  const LooseBinary(this.path, this.relativePath, this.identifier);

  final String path;
  final String relativePath;
  final String identifier;
}
