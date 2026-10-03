import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

final class SwiftPmWorkspace {
  const SwiftPmWorkspace._({
    required this.cacheRoot,
    required this.root,
    required this.simulator,
  });

  final String cacheRoot;
  final String root;
  final bool simulator;

  String get binaryArtifactStore => p.join(
    cacheRoot,
    'swiftpm',
    simulator ? 'binary-artifacts-simulator-v1' : 'binary-artifacts-v1',
  );
  String get binaryArtifactFallback => p.join(root, 'binary-artifacts');
  String get gateEvidence => p.join(cacheRoot, 'swiftpm', 'gate-evidence-v2');
  String get gateIdentityCache => p.join(gateEvidence, 'build-identities.json');
  String get gateCapabilityCache => p.join(gateEvidence, 'capabilities.json');

  String get packages => p.join(root, 'plugins');
  String get scratch => p.join(root, 'scratch');
  String get vendor => p.join(root, 'vendor');

  factory SwiftPmWorkspace.forProject(
    String projectRoot, {
    Map<String, String>? environment,
    bool? windows,
    bool simulator = false,
  }) {
    final env = environment ?? Platform.environment;
    final cache = env['XCROSS_CACHE_DIR'];
    final base = cache != null && cache.isNotEmpty
        ? cache
        : _defaultCacheRoot(env, windows: windows);
    final canonical = _canonicalProjectPath(projectRoot);
    final key = sha256
        .convert(utf8.encode(canonical))
        .toString()
        .substring(0, 16);
    return SwiftPmWorkspace._(
      cacheRoot: base,
      simulator: simulator,
      root: p.join(base, 'swiftpm', simulator ? '$key-simulator' : key),
    );
  }

  static String _defaultCacheRoot(
    Map<String, String> environment, {
    bool? windows,
  }) {
    if (windows ?? Platform.isWindows) {
      final localAppData = environment['LOCALAPPDATA'];
      if (localAppData != null && localAppData.isNotEmpty) {
        return p.join(localAppData, 'xcross');
      }
    }
    final xdg = environment['XDG_CACHE_HOME'];
    if (xdg != null && xdg.isNotEmpty) return p.join(xdg, 'xcross');
    final home = environment['HOME'] ?? environment['USERPROFILE'] ?? '.';
    return p.join(home, '.cache', 'xcross');
  }

  static String _canonicalProjectPath(String projectRoot) {
    final absolute = p.normalize(p.absolute(projectRoot));
    try {
      final resolved = Directory(absolute).resolveSymbolicLinksSync();
      return Platform.isWindows ? resolved.toLowerCase() : resolved;
    } on FileSystemException {
      return Platform.isWindows ? absolute.toLowerCase() : absolute;
    }
  }
}
