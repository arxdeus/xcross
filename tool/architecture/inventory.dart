import 'boundaries.dart';
export 'boundaries.dart';

Classification classify(String path) {
  final parts = path.split('/');
  if (parts.length > 2 &&
      parts[0] == 'packages' &&
      workspacePackages.contains(parts[1]) &&
      parts[2] == 'test') {
    return const Classification('shared', 'shared', 'test');
  }
  String axis(String label, Set<String> choices) {
    final index = parts.indexOf(label);
    return index >= 0 &&
            index + 1 < parts.length &&
            choices.contains(parts[index + 1])
        ? parts[index + 1]
        : 'shared';
  }

  final host = axis('host', {'windows', 'linux', 'macos', 'shared'});
  final target = axis('target', {'iphone', 'simulator', 'shared'});
  if (resources.containsKey(path)) return resources[path]!;
  if (templates.contains(path)) return Classification(host, target, 'template');
  if (nativeSources.containsKey(path)) {
    return Classification(nativeSources[path]!, 'shared', 'native-abi');
  }
  if (nativeHooks.contains(path)) {
    return const Classification('shared', 'shared', 'native-hook');
  }
  if (compositions.contains(path)) {
    return const Classification('shared', 'shared', 'composition');
  }
  if (hostFactories.containsKey(path)) {
    return Classification(hostFactories[path]!, 'shared', 'host-composition');
  }
  if (ciFiles.containsKey(path)) return ciFiles[path]!;
  if (path == 'tool/architecture/check_test.dart') {
    return const Classification('shared', 'shared', 'architecture-test');
  }
  if (architectureSources.contains(path)) {
    return const Classification('shared', 'shared', 'architecture-tool');
  }
  if (toolBoundaries.contains(path)) {
    return const Classification('shared', 'shared', 'tool');
  }
  if (entrypoints.contains(path)) {
    return const Classification('shared', 'shared', 'entrypoint');
  }
  final lib = parts.indexOf('lib');
  if (lib >= 0 && lib + 2 == parts.length && path.endsWith('.dart')) {
    return const Classification('shared', 'shared', 'barrel');
  }
  final hostIndex = parts.indexOf('host');
  final targetIndex = parts.indexOf('target');
  if ((hostIndex >= 0 &&
          (hostIndex + 1 >= parts.length ||
              !{
                'windows',
                'linux',
                'macos',
                'shared',
              }.contains(parts[hostIndex + 1]))) ||
      (targetIndex >= 0 &&
          (targetIndex + 1 >= parts.length ||
              !{
                'iphone',
                'simulator',
                'shared',
              }.contains(parts[targetIndex + 1])))) {
    return Classification(host, target, 'unclassified');
  }
  if (path.contains('/lib/src/shared/') ||
      path.contains('/lib/src/host/') ||
      path.contains('/lib/src/target/')) {
    final kind = path.endsWith('.g.dart')
        ? 'generated'
        : path.endsWith('.dart')
        ? 'dart'
        : 'unclassified';
    return Classification(host, target, kind);
  }
  return Classification(host, target, 'unclassified');
}
