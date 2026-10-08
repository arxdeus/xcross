/// Rules that keep platform behaviour on polymorphic contracts instead of
/// visitors, per-platform callback bundles, or service locators.
library;

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

import 'package:repo_analyzer/src/conventions.dart';
import 'package:repo_analyzer/src/platform_types.dart';
import 'package:repo_analyzer/src/rule_base.dart';

/// Reports visitor-style double dispatch over platforms.
final class PlatformVisitorRule extends ArchitectureRule {
  PlatformVisitorRule()
    : super(
        warning(
          'platform_visitor',
          'Platform visitor or accept-style double dispatch: {0}.',
          'Put the behavior on the platform contract and let composition '
              'pick the implementation.',
        ),
        description:
            'Platforms must not be visited (visitWindows/visitLinux, '
            'accept(visitor), or per-platform method objects).',
      );

  @override
  bool appliesTo(SourceLocation location) => location.zone != Zone.other;

  static bool _analyzerType(Element? element) =>
      element?.library?.uri.toString().startsWith('package:analyzer/') ?? false;

  @override
  void check(CompilationUnit unit, RuleScope scope) {
    walk(unit, (node) {
      if (node is ClassDeclaration) {
        final element = node.declaredFragment?.element;
        final name = node.namePart.typeName.lexeme;
        final visits = node.body is BlockClassBody
            ? (node.body as BlockClassBody).members
                  .whereType<MethodDeclaration>()
                  .map((m) => m.name.lexeme)
                  .where(
                    (n) =>
                        n.startsWith('visit') &&
                        platformLabels.any(
                          (l) => n.substring(5).toLowerCase().startsWith(l),
                        ),
                  )
                  .length
            : 0;
        if ((isPlatformElement(element) && name.contains('Visitor')) ||
            visits >= 2 ||
            name.contains('HostVisitor') ||
            name.contains('TargetVisitor')) {
          reportAtToken(node.namePart.typeName, arguments: ['declaration']);
        } else if (element != null && _protocol(element)) {
          reportAtToken(
            node.namePart.typeName,
            arguments: ['per-platform method object'],
          );
        }
      } else if (node is MethodDeclaration &&
          node.name.lexeme == 'accept' &&
          isPlatformElement(
            node
                .thisOrAncestorOfType<ClassDeclaration>()
                ?.declaredFragment
                ?.element,
          )) {
        reportAtToken(node.name, arguments: ['accept declaration']);
      } else if (node is MethodInvocation &&
          node.methodName.name == 'accept' &&
          isPlatformType(node.realTarget?.staticType)) {
        reportAtNode(node.methodName, arguments: ['accept dispatch']);
      } else if (node is NamedType) {
        final type = node.type;
        if (type is InterfaceType &&
            !_analyzerType(type.element) &&
            (type.element.name?.contains('Visitor') ?? false) &&
            isPlatformElement(type.element) &&
            node
                    .thisOrAncestorOfType<ClassDeclaration>()
                    ?.declaredFragment
                    ?.element !=
                type.element) {
          reportAtNode(node, arguments: ['visitor type']);
        }
      }
    });
  }
}

/// Whether methods of [element] accept two or more distinct platform variants.
bool _protocol(InterfaceElement element) {
  final variants = <InterfaceElement>{
    for (final method in element.methods)
      for (final parameter in method.formalParameters)
        ...platformVariants(parameter.type),
  };
  return variants.length >= 2;
}

int _callbacks(DartType? type, [Set<InterfaceElement>? seen]) {
  final visited = seen ?? <InterfaceElement>{};
  if (type is FunctionType) return 1;
  if (type is RecordType) {
    return [
      ...type.namedFields.map((f) => f.type),
      ...type.positionalFields.map((f) => f.type),
    ].fold(0, (n, t) => n + _callbacks(t, visited));
  }
  if (type is InterfaceType &&
      {'List', 'Iterable', 'Map', 'Set'}.contains(type.element.name) &&
      type.element.library.isDartCore &&
      type.typeArguments.any((t) => _callbacks(t, visited) > 0)) {
    return 2;
  }
  if (type is InterfaceType && visited.add(type.element)) {
    if (_protocol(type.element)) return 2;
    if (type.element.library.uri.scheme == 'dart') return 0;
    return type.element.fields
        .where((f) => !f.isStatic)
        .fold(0, (n, f) => n + _callbacks(f.type, visited));
  }
  return 0;
}

/// Reports per-platform callback bundles and service locators on platforms.
final class PlatformCallbackDispatchRule extends ArchitectureRule {
  PlatformCallbackDispatchRule()
    : super(
        warning(
          'platform_callback_dispatch',
          'Platform API {0}.',
          'Expose one polymorphic operation on the platform contract.',
        ),
        description:
            'Host/target types must not take per-platform callback bundles '
            'or act as generic service locators.',
      );

  @override
  bool appliesTo(SourceLocation location) => location.zone != Zone.other;

  @override
  void check(CompilationUnit unit, RuleScope scope) {
    for (final declaration in unit.declarations.whereType<ClassDeclaration>()) {
      final type = declaration.declaredFragment?.element;
      if (type == null || !isPlatformElement(type)) continue;
      for (final method in type.methods) {
        final offset = method.firstFragment.nameOffset ?? declaration.offset;
        final length = method.name?.length ?? 0;
        if (method.formalParameters.fold<int>(
              0,
              (n, p) => n + _callbacks(p.type),
            ) >=
            2) {
          reportAtOffset(
            offset,
            length,
            arguments: ['takes a per-platform callback bundle'],
          );
        }
        if (method.name == 'get' && method.typeParameters.isNotEmpty) {
          reportAtOffset(
            offset,
            length,
            arguments: ['is a generic service locator'],
          );
        }
      }
      for (final constructor in type.constructors) {
        final variants = <InterfaceElement>{
          for (final parameter in constructor.formalParameters)
            if (parameter.type is FunctionType)
              for (final argument
                  in (parameter.type as FunctionType).formalParameters)
                ...platformVariants(argument.type),
        };
        if (variants.length >= 2 ||
            constructor.formalParameters.fold<int>(
                  0,
                  (n, p) => n + _callbacks(p.type),
                ) >=
                2) {
          reportAtToken(
            declaration.namePart.typeName,
            arguments: ['stores per-platform callbacks'],
          );
          break;
        }
      }
    }
  }
}
