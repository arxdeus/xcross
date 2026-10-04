import 'package:meta/meta.dart';

import 'boundaries.dart';

@internal
int structuralPrimary(String path) {
  final parts = path.split('/');
  if (parts.length < 5 || parts[0] != 'packages' || parts[2] != 'lib') {
    return -1;
  }
  return parts[3] == 'src' ? 4 : 3;
}

@internal
Classification classify(String path) {
  final parts = path.split('/');
  if (parts.length > 2 &&
      parts[0] == 'packages' &&
      workspacePackages.contains(parts[1]) &&
      parts[2] == 'test') {
    return const Classification('shared', 'shared', 'test');
  }
  final primary = structuralPrimary(path);
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
  if (path == 'tool/architecture/check_test.dart' ||
      path == 'tool/architecture/source_policy_test.dart') {
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
  for (final (label, choices) in [
    ('host', {'windows', 'linux', 'macos', 'shared'}),
    ('target', {'iphone', 'simulator', 'shared'}),
  ]) {
    final index = axisIndex(label);
    if (index >= 0 &&
        (index + 1 >= parts.length - 1 ||
            !choices.contains(parts[index + 1]))) {
      return Classification(host, target, 'unclassified');
    }
  }
  if (primary >= 0 &&
      primary < parts.length - 1 &&
      {'shared', 'host', 'target'}.contains(parts[primary])) {
    return Classification(
      host,
      target,
      path.endsWith('.g.dart')
          ? 'generated'
          : path.endsWith('.dart')
          ? 'dart'
          : 'unclassified',
    );
  }
  return Classification(host, target, 'unclassified');
}
