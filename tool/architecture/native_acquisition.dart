import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';

import 'inventory.dart';

class NativeAcquisitionRules extends RecursiveAstVisitor<void> {
  final String path;
  final List<Violation> violations = [];
  NativeAcquisitionRules(this.path);
  static const constructors = {'File', 'Directory', 'Link', 'HttpClient'};
  static const endpoints = {
    'Process': {'run', 'runSync', 'start'},
    'Socket': {'connect', 'startConnect'},
    'ServerSocket': {'bind'},
  };
  bool get enabled {
    final parts = path.split('/');
    return parts.length > 5 &&
        parts[0] == 'packages' &&
        parts[2] == 'lib' &&
        parts[3] == 'src' &&
        {'shared', 'target'}.contains(parts[4]);
  }

  void reject(AstNode node, Element element) {
    violations.add(
      Violation(
        path,
        'native-acquisition',
        node.offset,
        'Native ${element.enclosingElement?.name}.${element.name} acquisition requires an injected selected port or supplied entity',
      ),
    );
  }

  void constructor(AstNode node, ConstructorName name) {
    final Element? element = name.element;
    if (enabled &&
        element != null &&
        (element.library?.uri.toString() == 'dart:io' ||
            element.library?.uri.toString() == 'dart:_http' &&
                element.enclosingElement?.name == 'HttpClient') &&
        constructors.contains(element.enclosingElement?.name)) {
      reject(node, element);
    }
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    constructor(node, node.constructorName);
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitConstructorReference(ConstructorReference node) {
    constructor(node, node.constructorName);
    super.visitConstructorReference(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final element = node.element;
    if (enabled &&
        element is ExecutableElement &&
        element is! ConstructorElement &&
        element.isStatic &&
        element.library.uri.toString() == 'dart:io') {
      final owner = element.enclosingElement?.name;
      if ({'FileSystemEntity', 'FileStat'}.contains(owner) ||
          endpoints[owner]?.contains(element.name) == true) {
        reject(node, element);
      }
    }
    super.visitSimpleIdentifier(node);
  }
}
