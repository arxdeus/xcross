/// Data-flow approximation of "this value carries platform identity".
///
/// Identity comes in three kinds:
/// * `host`: operating system identity (`Platform.isWindows`,
///   `host.operatingSystem`, `is WindowsHostInterface`, `'linux'` literals).
/// * `architecture`: CPU architecture (`Abi.current()`, `host.architecture`).
/// * `target`: target device identity (`target.sdkName`).
///
/// Aliases (locals, fields, getters) that are assigned identity are discovered
/// to a fixed point across the library being analyzed.
library;

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

import 'package:repo_analyzer/src/platform_types.dart';

const kindHost = 'host';
const kindArchitecture = 'architecture';
const kindTarget = 'target';

final class IdentityAnalysis {
  IdentityAnalysis(Iterable<CompilationUnit> units) {
    final list = units.toList();
    for (;;) {
      final before = _size;
      for (final unit in list) {
        _discover(unit);
      }
      if (_size == before) break;
    }
  }

  final Map<Element, Set<String>> aliases = {};

  int get _size => aliases.values.fold(0, (sum, kinds) => sum + kinds.length);

  /// Whether [element] reads ambient process or machine state.
  static bool isRuntimeAccess(Element? element) {
    final uri = element?.library?.uri.toString();
    final owner = element?.enclosingElement?.name;
    final name = element?.name;
    return (uri == 'dart:io' &&
            (element?.enclosingElement is LibraryElement &&
                    {'stdin', 'stdout', 'stderr'}.contains(name) ||
                owner == 'Directory' &&
                    {'current', 'systemTemp'}.contains(name))) ||
        (uri?.startsWith('package:code_assets/') == true &&
            {'OS', 'Architecture'}.contains(owner) &&
            name == 'current') ||
        (uri == 'dart:ffi' && owner == 'Abi' && name == 'current') ||
        (uri == 'dart:io' && owner == 'Platform' && name != null);
  }

  Set<String> member(Element? element) {
    if (element == null) return const {};
    final alias = aliases[element];
    if (alias != null) return alias;
    final name = element.name;
    final owner = element.enclosingElement;
    final uri = element.library?.uri.toString();
    if (uri == 'dart:io' && owner?.name == 'Platform') {
      if (name == 'operatingSystem' || isIdentityFlag(name)) return {kindHost};
    }
    if (uri == 'dart:ffi' && owner?.name == 'Abi' && name == 'current') {
      return {kindArchitecture};
    }
    if (uri?.startsWith('package:code_assets/') == true) {
      if (name == 'targetOS' ||
          owner?.name == 'OS' &&
              {'windows', 'linux', 'macOS', 'current'}.contains(name)) {
        return {kindHost};
      }
      if (name == 'targetArchitecture' ||
          owner?.name == 'Architecture' && name == 'current') {
        return {kindArchitecture};
      }
    }
    // Any instance field/getter typed `Abi` (for example a host snapshot's
    // `abi`) carries the architecture it was captured from. `Abi` constants
    // such as `Abi.linuxX64` are descriptors, not identity.
    if ((element is FieldElement && !element.isStatic ||
            element is GetterElement && !element.isStatic) &&
        element.library?.uri.scheme != 'dart') {
      final type = element is FieldElement
          ? element.type
          : (element as GetterElement).returnType;
      if (_isAbi(type)) return {kindArchitecture};
    }
    if (isPlatformOwned(element)) {
      if (name == 'architecture') return {kindArchitecture};
      if (isIdentityFlag(name) || hostIdentityMembers.contains(name)) {
        return {kindHost};
      }
      if (targetIdentityMembers.contains(name)) return {kindTarget};
    }
    if (element is FormalParameterElement &&
        element.type.isDartCoreBool &&
        isIdentityFlag(name)) {
      return {kindHost};
    }
    return const {};
  }

  static bool _isAbi(DartType type) =>
      type is InterfaceType &&
      type.element.name == 'Abi' &&
      type.element.library.uri.toString() == 'dart:ffi';

  Set<String> value(AstNode? node) {
    if (node == null) return const {};
    if (node is SimpleIdentifier) return member(node.element);
    if (node is PrefixedIdentifier) return member(node.identifier.element);
    if (node is PropertyAccess) return member(node.propertyName.element);
    if (node is MethodInvocation) {
      return {...member(node.methodName.element), ...value(node.target)};
    }
    if (node is ParenthesizedExpression) return value(node.expression);
    if (node is PrefixExpression) return value(node.operand);
    if (node is IsExpression && isPlatformType(node.type.type)) {
      return {kindHost};
    }
    if (node is BinaryExpression &&
        const {
          '==',
          '!=',
          '<',
          '>',
          '<=',
          '>=',
          '&&',
          '||',
        }.contains(node.operator.lexeme)) {
      return {...value(node.leftOperand), ...value(node.rightOperand)};
    }
    if (node is ConditionalExpression) {
      return {...value(node.thenExpression), ...value(node.elseExpression)};
    }
    if (node is SwitchExpression) {
      final result = <String>{};
      for (final item in node.cases) {
        result.addAll(value(item.expression));
      }
      if (result.isNotEmpty) result.addAll(control(node.expression));
      return result;
    }
    return const {};
  }

  /// Identity kinds that influence a control-flow [node].
  Set<String> control(AstNode node) {
    final result = <String>{...value(node)};
    for (final child in astNodes(node)) {
      if (child is IsExpression && isPlatformType(child.type.type)) {
        result.add(kindHost);
      }
      if (child is NamedType && isPlatformType(child.type)) {
        result.add(kindHost);
      }
      if (child is SimpleIdentifier) result.addAll(member(child.element));
      if (child is StringLiteral &&
          platformLabels.contains(child.stringValue)) {
        result.add(kindHost);
      }
    }
    return result;
  }

  Set<String> returns(FunctionBody body) {
    if (body is ExpressionFunctionBody) return value(body.expression);
    return {
      for (final node in astNodes(body).whereType<ReturnStatement>())
        ...value(node.expression),
    };
  }

  void _discover(CompilationUnit unit) {
    for (final node in astNodes(unit)) {
      Element? element;
      var kind = const <String>{};
      if (node is AssignmentExpression &&
          node.leftHandSide is SimpleIdentifier) {
        element = (node.leftHandSide as SimpleIdentifier).element;
        kind = value(node.rightHandSide);
      } else if (node is VariableDeclaration) {
        element = node.declaredFragment?.element;
        kind = value(node.initializer);
      } else if (node is MethodDeclaration) {
        element = node.declaredFragment?.element;
        kind = returns(node.body);
      } else if (node is FunctionDeclaration) {
        element = node.declaredFragment?.element;
        kind = returns(node.functionExpression.body);
      }
      if (element != null && kind.isNotEmpty) {
        aliases.putIfAbsent(element, () => {}).addAll(kind);
      }
    }
  }
}
