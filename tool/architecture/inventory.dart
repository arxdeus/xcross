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
  final source = parts.indexOf('src');
  final primary = source < 0 ? -1 : source + 1;
  int axisIndex(String label) {
    if (primary < 0 || primary >= parts.length) return -1;
    if (parts[primary] == label) return primary;
    if ({'host', 'target'}.contains(parts[primary]) &&
        primary + 2 < parts.length &&
        parts[primary + 2] == label) {
      return primary + 2;
    }
    return -1;
  }

  String axis(String label, Set<String> choices) {
    final index = axisIndex(label);
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
  if (generatedCompositionParts.containsKey(path)) {
    return const Classification('shared', 'shared', 'generated-composition');
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
  final hostIndex = axisIndex('host');
  final targetIndex = axisIndex('target');
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
