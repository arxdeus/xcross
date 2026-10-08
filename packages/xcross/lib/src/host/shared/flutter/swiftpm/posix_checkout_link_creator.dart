import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_link_creator.dart';

@internal
final class PosixSwiftPmCheckoutLinkCreator
    implements SwiftPmCheckoutLinkCreator {
  const PosixSwiftPmCheckoutLinkCreator(this.fileSystem);
  final SwiftPmArtifactFileSystem fileSystem;
  @override
  void create(String link, String target) =>
      fileSystem.link(link).createSync(target);
}
