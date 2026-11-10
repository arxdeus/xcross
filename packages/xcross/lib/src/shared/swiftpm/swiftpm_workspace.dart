import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/target/shared/swiftpm/swiftpm_target_policy.dart';

@internal
final class SwiftPmWorkspace {
  factory SwiftPmWorkspace.forProject(
    String projectRoot, {
    required SwiftPmTargetPolicy policy,
    Map<String, String>? environment,
  }) {
    final host = policy.target.host;
    final env = environment ?? host.environment.values;
    final cache = env['XCROSS_CACHE_DIR'];
    final base = cache != null && cache.isNotEmpty
        ? cache
        : p.join(host.paths.cacheRoot, 'xcross');
    final canonical = _canonicalProjectPath(projectRoot, policy);
    final key = sha256
        .convert(utf8.encode(canonical))
        .toString()
        .substring(0, 16);
    return SwiftPmWorkspace._(
      cacheRoot: base,
      policy: policy,
      root: p.join(base, 'swiftpm', '$key${policy.workspaceSuffix}'),
    );
  }
  const SwiftPmWorkspace._({
    required this.cacheRoot,
    required this.root,
    required this.policy,
  });

  final String cacheRoot;
  final String root;
  final SwiftPmTargetPolicy policy;

  String get binaryArtifactStore =>
      p.join(cacheRoot, 'swiftpm', policy.binaryArtifactDirectory);
  String get binaryArtifactFallback => p.join(root, 'binary-artifacts');
  String get gateEvidence => p.join(cacheRoot, 'swiftpm', 'gate-evidence-v2');
  String get gateIdentityCache => p.join(gateEvidence, 'build-identities.json');
  String get gateCapabilityCache => p.join(gateEvidence, 'capabilities.json');

  String get packages => p.join(root, 'plugins');
  String get scratch => p.join(root, 'scratch');

  static String _canonicalProjectPath(
    String projectRoot,
    SwiftPmTargetPolicy policy,
  ) {
    final ctx = policy.target.host.paths.context;
    final absolute = ctx.normalize(ctx.absolute(projectRoot));
    try {
      final resolved = policy.target.host.fileSystem
          .directory(absolute)
          .resolveSymbolicLinksSync();
      return policy.target.host.paths.pathKey(resolved);
    } on FileSystemException {
      return policy.target.host.paths.pathKey(absolute);
    }
  }
}
