import 'package:cli_kit/cli_kit.dart';
import 'package:xcross/src/flutter/build/internal/host_symlink_capability.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_attributes.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_git_repository.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_graph.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_link_creator.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_link_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_links.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_stamp.dart';
import 'package:xcross/src/shared/flutter/swiftpm/filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/host_source_normalizer.dart';
import 'package:xcross/src/shared/flutter/swiftpm/module_files.dart';
import 'package:xcross/src/shared/flutter/swiftpm/source_fallback.dart';

final class SwiftPmCheckoutAssemblyParts<T extends PlatformHostInterface> {
  factory SwiftPmCheckoutAssemblyParts.prepare({required ProcessRunner<T> runner, required SwiftPmArtifactFileSystem fileSystem}) {
    final filesystem = SwiftPmFilesystem<T>(host: runner.host, runner: runner, artifactFileSystem: fileSystem);
    return SwiftPmCheckoutAssemblyParts._(runner: runner, fileSystem: fileSystem, filesystem: filesystem, symlinks: HostSymlinkCapability(runner.host), stamps: SwiftPmCheckoutStampValidator(fileSystem: fileSystem), graph: SwiftPmCheckoutGraph(fileSystem: fileSystem), sourceNormalizer: SwiftPmHostSourceNormalizer(fileSystem: fileSystem), sourceFallback: SwiftPmSourceFallback<T>(filesystem: filesystem, moduleFiles: SwiftPmModuleFiles(fileSystem: fileSystem)));
  }
  const SwiftPmCheckoutAssemblyParts._({required this.runner, required this.fileSystem, required this.filesystem, required this.symlinks, required this.stamps, required this.graph, required this.sourceNormalizer, required this.sourceFallback});
  final ProcessRunner<T> runner;
  final SwiftPmArtifactFileSystem fileSystem;
  final SwiftPmFilesystem<T> filesystem;
  final HostSymlinkCapability symlinks;
  final SwiftPmCheckoutStampValidator stamps;
  final SwiftPmCheckoutGraph graph;
  final SwiftPmHostSourceNormalizer sourceNormalizer;
  final SwiftPmSourceFallback<T> sourceFallback;
}

SwiftPmCheckout<T> assembleSwiftPmCheckout<T extends PlatformHostInterface>({required SwiftPmCheckoutAssemblyParts<T> parts, required SwiftPmCheckoutGitPolicy gitPolicy, required SwiftPmCheckoutFallback fallback, required SwiftPmCheckoutAttributes attributes, required SwiftPmCheckoutLinkCreator linkCreator, required Map<String, String> environment}) {
  final repository = SwiftPmGitRepository<T>(runner: parts.runner, fileSystem: parts.fileSystem, filesystem: parts.filesystem, policy: gitPolicy, environment: environment);
  final links = SwiftPmCheckoutLinks<T>(runner: parts.runner, fileSystem: parts.fileSystem, stamps: parts.stamps, attributes: attributes, linkCreator: linkCreator, policy: gitPolicy);
  return SwiftPmCheckout<T>(runner: parts.runner, fileSystem: parts.fileSystem, symlinks: parts.symlinks, stamps: parts.stamps, graph: parts.graph, repository: repository, links: links, fallback: fallback);
}
