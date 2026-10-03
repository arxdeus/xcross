import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

Iterable<AstNode> astNodes(AstNode node) sync* {
  yield node;
  for (final child in node.childEntities.whereType<AstNode>()) {
    yield* astNodes(child);
  }
}

class IdentityAnalysis {
  final Map<Element, Set<String>> aliases = {};
  static const types = {
    'PlatformHostInterface',
    'PlatformTargetInterface',
    'WindowsHostInterface',
    'LinuxHostInterface',
    'MacOSHostInterface',
    'WindowsHost',
    'LinuxHost',
    'MacOSHost',
    'IosTarget',
    'IPhoneTarget',
    'SimulatorTarget',
    'IPhoneTargetInterface',
    'SimulatorTargetInterface',
    'IosBuildPlatformInterface',
    'IPhoneBuildPlatform',
    'SimulatorBuildPlatform',
  };
  static const labels = {
    'windows',
    'linux',
    'macos',
    'iphone',
    'simulator',
    'iphoneos',
    'iphonesimulator',
  };
  static const flags = {
    'isWindows',
    'isLinux',
    'isMacOS',
    'isIOS',
    'isAndroid',
    'isSimulator',
    'isIPhone',
  };

  bool platformType(DartType? type) =>
      type is InterfaceType &&
      (types.contains(type.element.name) ||
          type.element.allSupertypes.any(
            (t) => types.contains(t.element.name),
          ));
  bool platformOwner(Element? element) {
    final owner = element?.enclosingElement;
    return owner is InterfaceElement &&
        (types.contains(owner.name) ||
            owner.allSupertypes.any((t) => types.contains(t.element.name)));
  }

  bool runtimeAccess(Element? element) {
    final uri = element?.library?.uri.toString();
    final owner = element?.enclosingElement?.name;
    return (uri == 'dart:io' &&
            (element?.enclosingElement is LibraryElement &&
                    {'stdin', 'stdout', 'stderr'}.contains(element?.name) ||
                owner == 'Directory' &&
                    {'current', 'systemTemp'}.contains(element?.name))) ||
        (uri?.startsWith('package:code_assets/') == true &&
            {'OS', 'Architecture'}.contains(owner) &&
            element?.name == 'current') ||
        (uri == 'dart:ffi' && owner == 'Abi' && element?.name == 'current') ||
        (uri == 'dart:io' && owner == 'Platform' && element?.name != null);
  }

  Set<String> member(Element? element) {
    if (element == null) return {};
    if (aliases.containsKey(element)) return aliases[element]!;
    final name = element.name;
    final uri = element.library?.uri.toString();
    if (uri == 'dart:io' && element.enclosingElement?.name == 'Platform') {
      if (name == 'operatingSystem' || flags.contains(name)) return {'host'};
    }
    if (uri == 'dart:ffi' &&
        element.enclosingElement?.name == 'Abi' &&
        name == 'current') {
      return {'architecture'};
    }
    if (uri?.startsWith('package:code_assets/') == true) {
      if (name == 'targetOS' ||
          element.enclosingElement?.name == 'OS' &&
              {'windows', 'linux', 'macOS', 'current'}.contains(name)) {
        return {'host'};
      }
      if (name == 'targetArchitecture' ||
          element.enclosingElement?.name == 'Architecture' && name == 'current') {
        return {'architecture'};
      }
    }
    if (element.enclosingElement?.name == 'NativeHostSnapshot' && name == 'abi') {
      return {'architecture'};
    }
    if (platformOwner(element)) {
      if (name == 'architecture') return {'architecture'};
      if (flags.contains(name) ||
          {
            'operatingSystem',
            'classifier',
            'name',
            'hostName',
          }.contains(name)) {
        return {'host'};
      }
      if ({'sdkName', 'targetPlatform'}.contains(name)) return {'target'};
    }
    if (element is FormalParameterElement &&
        element.type.isDartCoreBool &&
        flags.contains(name)) {
      return {'host'};
    }
    return {};
  }

  Set<String> value(AstNode? node) {
    if (node == null) return {};
    if (node is SimpleIdentifier) return member(node.element);
    if (node is PrefixedIdentifier) return member(node.identifier.element);
    if (node is PropertyAccess) return member(node.propertyName.element);
    if (node is MethodInvocation) {
      return {...member(node.methodName.element), ...value(node.target)};
    }
    if (node is ParenthesizedExpression) return value(node.expression);
    if (node is PrefixExpression) return value(node.operand);
    if (node is IsExpression && platformType(node.type.type)) return {'host'};
    if (node is BinaryExpression &&
        {
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
    return {};
  }

  Set<String> control(AstNode node) {
    final result = <String>{...value(node)};
    for (final child in astNodes(node)) {
      if (child is IsExpression && platformType(child.type.type)) {
        result.add('host');
      }
      if (child is NamedType && platformType(child.type)) result.add('host');
      if (child is SimpleIdentifier) result.addAll(member(child.element));
      if (child is StringLiteral && labels.contains(child.stringValue)) {
        result.add('host');
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

  void discover(CompilationUnit unit) {
    for (final node in astNodes(unit)) {
      Element? element;
      var kind = <String>{};
      if (node is AssignmentExpression &&
          node.leftHandSide is SimpleIdentifier) {
        element = (node.leftHandSide as SimpleIdentifier).element;
        kind = value(node.rightHandSide);
      }
      if (node is VariableDeclaration) {
        element = node.declaredFragment?.element;
        kind = value(node.initializer);
      }
      if (node is MethodDeclaration) {
        element = node.declaredFragment?.element;
        kind = returns(node.body);
      }
      if (node is FunctionDeclaration) {
        element = node.declaredFragment?.element;
        kind = returns(node.functionExpression.body);
      }
      if (element != null && kind.isNotEmpty) {
        aliases.putIfAbsent(element, () => {}).addAll(kind);
      }
    }
  }
}
