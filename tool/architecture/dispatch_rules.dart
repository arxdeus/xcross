import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'identity.dart';
import 'inventory.dart';

class DispatchRules {
  final String path;
  final List<Violation> violations = [];
  DispatchRules(this.path);
  Set<String> axes(DartType? type) {
    if (type is! InterfaceType) return {};
    final names = {
      type.element.name,
      ...type.element.allSupertypes.map((t) => t.element.name),
    };
    return {
      if (names.contains('WindowsHostInterface') ||
          names.contains('WindowsHost'))
        'windows',
      if (names.contains('LinuxHostInterface') || names.contains('LinuxHost'))
        'linux',
      if (names.contains('MacOSHostInterface') || names.contains('MacOSHost'))
        'macos',
      if (names.contains('IPhoneTargetInterface') ||
          names.contains('IPhoneTarget'))
        'iphone',
      if (names.contains('SimulatorTargetInterface') ||
          names.contains('SimulatorTarget'))
        'simulator',
    };
  }

  bool protocol(InterfaceElement element) {
    final kinds = {
      for (final method in element.methods)
        for (final parameter in method.formalParameters)
          ...axes(parameter.type),
    };
    return kinds.length >= 2;
  }

  int callbacks(DartType? type, [Set<InterfaceElement>? seen]) {
    final visited = seen ?? <InterfaceElement>{};
    if (type is FunctionType) return 1;
    if (type is RecordType) {
      return [
        ...type.namedFields.map((f) => f.type),
        ...type.positionalFields.map((f) => f.type),
      ].fold(0, (n, t) => n + callbacks(t, visited));
    }
    if (type is InterfaceType &&
        {'List', 'Iterable', 'Map', 'Set'}.contains(type.element.name) &&
        type.typeArguments.any((t) => callbacks(t, visited) > 0)) {
      return 2;
    }
    if (type is InterfaceType && visited.add(type.element)) {
      if (protocol(type.element)) return 2;
      return type.element.fields
          .where((f) => !f.isStatic)
          .fold(0, (n, f) => n + callbacks(f.type, visited));
    }
    return 0;
  }

  bool platform(ClassElement? type) =>
      type != null &&
      (IdentityAnalysis.types.contains(type.name) ||
          type.allSupertypes.any(
            (t) => IdentityAnalysis.types.contains(t.element.name),
          ));
  void inspect(ClassDeclaration node) {
    final type = node.declaredFragment?.element;
    if (type == null) return;
    if (protocol(type)) {
      violations.add(
        Violation(
          path,
          'visitor',
          node.offset,
          'Per-platform method object is renamed platform Visitor',
        ),
      );
    }
    if (!platform(type)) return;
    for (final method in type.methods) {
      if (method.formalParameters.fold<int>(
            0,
            (n, p) => n + callbacks(p.type),
          ) >=
          2) {
        violations.add(
          Violation(
            path,
            'callback-dispatch',
            method.firstFragment.nameOffset ?? node.offset,
            'Platform API takes callback bundle or per-platform method object',
          ),
        );
      }
      if (method.name == 'get' && method.typeParameters.isNotEmpty) {
        violations.add(
          Violation(
            path,
            'service-locator',
            method.firstFragment.nameOffset ?? node.offset,
            'Generic platform service locator',
          ),
        );
      }
    }
    for (final constructor in type.constructors) {
      final kinds = {
        for (final parameter in constructor.formalParameters)
          if (parameter.type is FunctionType)
            for (final argument
                in (parameter.type as FunctionType).formalParameters)
              ...axes(argument.type),
      };
      if (kinds.length >= 2 ||
          constructor.formalParameters.fold<int>(
                0,
                (n, p) => n + callbacks(p.type),
              ) >=
              2) {
        violations.add(
          Violation(
            path,
            'callback-dispatch',
            node.offset,
            'Constructor stores per-platform callbacks',
          ),
        );
      }
    }
  }
}
