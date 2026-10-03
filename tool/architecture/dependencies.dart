import 'package:analyzer/dart/ast/ast.dart';

import 'export_graph.dart';
import 'inventory.dart';

class DependencyRules {
  final String path;
  final Classification classification;
  final ExportGraph exportGraph;
  final List<Violation> violations = [];
  DependencyRules(this.path, this.exportGraph)
    : classification = classify(path);
  void reject(AstNode node, String rule, String detail) =>
      violations.add(Violation(path, rule, node.offset, detail));
  bool get composesHost => path == detector || path == hostComposition;
  bool get composesTarget => targetComposition.contains(path);
  void importEdge(AstNode node, String? uri) {
    if (uri == null || uri.startsWith('dart:')) return;
    final resolved = resolveUri(path, uri);
    final pending = {resolved, ...exportGraph.destinations(path, uri, node)};
    for (final destinationPath in pending) {
      final destination = classify(destinationPath);
      if (node is Directive &&
          destinationPath.startsWith('packages/') &&
          workspacePackages.contains(destinationPath.split('/')[1]) &&
          destination.kind == 'unclassified') {
        reject(
          node,
          'legacy-edge',
          'Production URI reaches unclassified or legacy path: $destinationPath',
        );
      }
      if (destination.kind == 'composition' &&
          !{
            'barrel',
            'composition',
            'host-composition',
            'entrypoint',
          }.contains(classification.kind) &&
          !(detectorCallers.containsKey(path) && destinationPath == detector))
        reject(
          node,
          'composition-edge',
          'Shared implementation reaches application composition: $destinationPath',
        );
      final concreteHost = destination.host != 'shared';
      final concreteTarget = destination.target != 'shared';
      if (classification.kind != 'barrel' &&
          ((classification.host != destination.host &&
                  concreteHost &&
                  !composesHost) ||
              (classification.target != destination.target &&
                  concreteTarget &&
                  !composesTarget &&
                  path != detector &&
                  !hostFactories.containsKey(path) &&
                  path !=
                      'packages/xcross/lib/src/composition/native_runtime.dart'))) {
        reject(
          node,
          'concrete-edge',
          'Shared source reaches concrete platform: $destinationPath',
        );
      }
      if (path.startsWith('packages/cli_kit/') &&
          destinationPath.startsWith('packages/') &&
          !destinationPath.startsWith('packages/cli_kit/') &&
          {
            'xcross',
            'darwin_sdk_kit',
            'apple_developer_kit',
            'dart_mobile_device',
            'frontend_server_kit',
          }.contains(destinationPath.split('/')[1])) {
        reject(node, 'dependency-direction', 'Core depends on higher layer');
      }
    }
  }
}
