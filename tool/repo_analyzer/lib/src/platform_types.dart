/// Type-level conventions shared by the architecture rules.
///
/// Nothing here lists concrete components. Platform identity is recognised
/// through the naming contract of the root platform interfaces, and effectful
/// services are inferred structurally from what they hold.
library;

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

/// Root host contract every host implements.
const platformHostRoot = 'PlatformHostInterface';

/// Root target contract every target implements.
const platformTargetRoot = 'PlatformTargetInterface';

/// Matches platform contracts: the `Platform*Interface` roots and every
/// `*PlatformInterface` descriptor (for example `IosBuildPlatformInterface`).
final _platformContract = RegExp(
  r'^Platform\w*Interface$|^\w+PlatformInterface$',
);

/// Host and target identity labels compared in conditions.
///
/// This is domain vocabulary, not a component registry: new hosts, targets,
/// and services never need to be added here. Generic family names such as
/// `ios` are deliberately absent because they appear in manifest data
/// (pubspec `platforms: ios:`, xcframework `SupportedPlatform`) that is
/// parsed, not dispatched on.
const platformLabels = {
  'windows',
  'linux',
  'macos',
  'iphone',
  'simulator',
  'iphoneos',
  'iphonesimulator',
};

/// `isWindows`, `isIPhone`, `isIOS`, ... identity flag names.
bool isIdentityFlag(String? name) =>
    name != null &&
    name.length > 2 &&
    name.startsWith('is') &&
    (platformLabels.contains(name.substring(2).toLowerCase()) ||
        const {'ios', 'android'}.contains(name.substring(2).toLowerCase()));

/// Members of platform types that carry host identity.
const hostIdentityMembers = {
  'operatingSystem',
  'classifier',
  'name',
  'hostName',
};

/// Members of platform types that carry target identity.
const targetIdentityMembers = {'sdkName', 'targetPlatform'};

Iterable<InterfaceElement> _selfAndSupertypes(InterfaceElement element) sync* {
  yield element;
  for (final type in element.allSupertypes) {
    yield type.element;
  }
}

/// Whether [element] is a platform contract or implements one.
bool isPlatformElement(InterfaceElement? element) =>
    element != null &&
    _selfAndSupertypes(
      element,
    ).any((e) => e.name != null && _platformContract.hasMatch(e.name!));

/// Whether [type] is (or is bounded by) a platform identity type.
bool isPlatformType(DartType? type) {
  if (type is TypeParameterType) return isPlatformType(type.bound);
  return type is InterfaceType && isPlatformElement(type.element);
}

/// Whether [type] is, implements, or is bounded by the host root contract.
bool isHostType(DartType? type) {
  if (type is TypeParameterType) return isHostType(type.bound);
  return type is InterfaceType &&
      _selfAndSupertypes(type.element).any((e) => e.name == platformHostRoot);
}

/// Whether [element] implements the target root contract.
bool isTargetElement(InterfaceElement? element) =>
    element != null &&
    _selfAndSupertypes(element).any((e) => e.name == platformTargetRoot);

/// Whether [element] is declared inside a platform type.
bool isPlatformOwned(Element? element) {
  final owner = element?.enclosingElement;
  return owner is InterfaceElement && isPlatformElement(owner);
}

/// The specialised platform contract variants (for example
/// `WindowsHostInterface` and `LinuxHostInterface`) that [type] belongs to.
///
/// Root contracts are excluded, so a method taking two *different* variants
/// reveals a per-platform dispatch protocol.
Set<InterfaceElement> platformVariants(DartType? type) {
  if (type is TypeParameterType) return platformVariants(type.bound);
  if (type is! InterfaceType || !isPlatformElement(type.element)) return {};
  final candidates = _selfAndSupertypes(type.element)
      .where(isPlatformElement)
      .where(
        (e) =>
            e.name != platformHostRoot &&
            e.name != platformTargetRoot &&
            e.allSupertypes.any((s) => isPlatformElement(s.element)),
      )
      .toSet();
  // Keep only the most general specialisations so `WindowsHost` and
  // `WindowsHostInterface` collapse to one variant.
  return {
    for (final candidate in candidates)
      if (!candidates.any(
        (other) =>
            other != candidate &&
            candidate.allSupertypes.any((s) => s.element == other),
      ))
        candidate,
  };
}

/// Native effect types that make a holder effectful.
const _nativeEffects = {
  'dart:io': {
    'HttpClient',
    'Process',
    'Socket',
    'ServerSocket',
    'RawSocket',
    'IOSink',
    'Stdout',
    'Stdin',
    'RandomAccessFile',
  },
  'dart:_http': {'HttpClient'},
};

/// Infers whether a type is an effectful session service.
///
/// A type is a service when it is a native effect handle, an HTTP client, a
/// platform host, an effect port, or (transitively) holds one in an instance
/// field. Function fields that produce a service count as holding it.
///
/// An effect port is an abstract interface declared outside the SDK whose
/// contract includes a command: a method returning `void` or a `Future`.
/// Pure strategy and descriptor interfaces only return values and are not
/// services.
final class ServiceInference {
  final Map<InterfaceElement, bool> _cache = {};

  bool isService(DartType? type) {
    if (type is TypeParameterType) return isHostType(type.bound);
    if (type is FunctionType) return false;
    if (type is! InterfaceType) return false;
    return _element(type.element);
  }

  bool _element(InterfaceElement element) {
    final cached = _cache[element];
    if (cached != null) return cached;
    _cache[element] = false; // Break cycles.
    final result = _compute(element);
    _cache[element] = result;
    return result;
  }

  bool _compute(InterfaceElement element) {
    for (final type in _selfAndSupertypes(element)) {
      final uri = type.library.uri.toString();
      if (_nativeEffects[uri]?.contains(type.name) ?? false) return true;
      if (uri.startsWith('package:http/') &&
          {'Client', 'BaseClient'}.contains(type.name)) {
        return true;
      }
      if (type.name == platformHostRoot) return true;
    }
    if (element.library.uri.scheme == 'dart') return false;
    if (_isEffectPort(element)) return true;
    for (final supertype in element.allSupertypes) {
      if (supertype.element.library.uri.scheme != 'dart' &&
          _element(supertype.element)) {
        return true;
      }
    }
    for (final field in element.fields) {
      if (field.isStatic) continue;
      final type = field.type;
      if (isService(type)) return true;
      if (type is FunctionType && isService(type.returnType)) return true;
    }
    return false;
  }

  bool _isEffectPort(InterfaceElement element) {
    if (element is! ClassElement || !element.isAbstract) return false;
    if (element.fields.any((f) => !f.isStatic && f.isOriginDeclaration))
      return false;
    return element.methods.any(
      (m) =>
          !m.isStatic &&
          m.isAbstract &&
          (m.returnType is VoidType || m.returnType.isDartAsyncFuture),
    );
  }

  /// Whether evaluating [expression] conjures a service from nothing.
  ///
  /// Constructions that receive an already-injected service as an argument
  /// derive a collaborator from injected effects and are not hidden roots.
  /// Types accepted by [allowed] are never reported.
  bool creates(Expression expression, {bool Function(DartType?)? allowed}) {
    final type = expression.staticType;
    final produced = type is FunctionType ? type.returnType : type;
    if (allowed != null && allowed(produced)) return false;
    if (expression is InstanceCreationExpression) {
      return isService(expression.staticType) &&
          !_derived(expression.argumentList);
    }
    if (expression is MethodInvocation) {
      // Calling a method on an object the class already holds is obtaining a
      // value from a collaborator, not conjuring one. Only top-level and
      // static factories create dependencies from nothing.
      final target = expression.realTarget;
      final staticCall =
          target is Identifier && target.element is InterfaceElement;
      if (target != null && !staticCall) return false;
      // Implicit-`this` instance methods only see injected state.
      final method = expression.methodName.element;
      if (target == null &&
          method is MethodElement &&
          !method.isStatic &&
          method.enclosingElement is InterfaceElement) {
        return false;
      }
      return isService(expression.staticType) &&
          expression.methodName.element is ExecutableElement &&
          !_derived(expression.argumentList);
    }
    if (type is! FunctionType || !isService(type.returnType)) return false;
    // A tear-off used as a step factory is the parameterised dependency
    // itself: it takes its effectful context as an argument.
    if (type.formalParameters.any((p) => isService(p.type))) {
      return false;
    }
    if (expression is ConstructorReference) return true;
    // The name of an invoked method is not a tear-off.
    final parent = expression.parent;
    if (parent is MethodInvocation &&
        identical(parent.methodName, expression)) {
      return false;
    }
    if (parent is PrefixedIdentifier &&
        identical(parent.identifier, expression)) {
      return false;
    }
    if (parent is PropertyAccess &&
        identical(parent.propertyName, expression)) {
      return false;
    }
    if (expression is SimpleIdentifier) {
      return expression.element is ExecutableElement;
    }
    if (expression is PrefixedIdentifier) {
      return expression.identifier.element is ExecutableElement;
    }
    if (expression is PropertyAccess) {
      return expression.propertyName.element is ExecutableElement;
    }
    return false;
  }

  bool _derived(ArgumentList arguments) => arguments.arguments.any((argument) {
    final expression = argument.argumentExpression;
    final type = expression.staticType;
    if (isService(type)) return true;
    // Values obtained from an injected service (`runtime.provider.resolve()`,
    // `runtime.host`) carry the injected effects.
    if (_fromService(expression)) return true;
    if (type is! FunctionType) return false;
    // A callback built from injected state (a tear-off of an injected
    // service's method, or any closure) carries injected effects.
    if (isService(type.returnType)) return true;
    if (expression is FunctionExpression) return true;
    final receiver = switch (expression) {
      PrefixedIdentifier() => expression.prefix.staticType,
      PropertyAccess() => expression.realTarget.staticType,
      _ => null,
    };
    return isService(receiver);
  });

  bool _fromService(Expression expression) => switch (expression) {
    MethodInvocation(:final realTarget?) =>
      isService(realTarget.staticType) || _fromService(realTarget),
    PrefixedIdentifier(:final prefix) => isService(prefix.staticType),
    PropertyAccess(:final realTarget) =>
      isService(realTarget.staticType) || _fromService(realTarget),
    _ => false,
  };

  /// Whether any sub-expression of [node] constructs a service.
  ///
  /// Sub-expressions that only feed a derived construction (arguments of a
  /// call that already receives injected state) are not inspected again.
  bool constructsIn(AstNode node, {bool Function(DartType?)? allowed}) =>
      astNodes(node).whereType<Expression>().any(
        (e) => !_feedsDerived(e) && creates(e, allowed: allowed),
      );

  bool _feedsDerived(Expression expression) {
    final call = expression.parent?.parent;
    final arguments = switch (call) {
      InstanceCreationExpression() => call.argumentList,
      MethodInvocation() => call.argumentList,
      _ => null,
    };
    return arguments != null &&
        identical(expression.parent, arguments) &&
        _fromService(expression);
  }
}

/// Depth-first iteration over [node] and its descendants.
Iterable<AstNode> astNodes(AstNode node) sync* {
  yield node;
  for (final child in node.childEntities.whereType<AstNode>()) {
    yield* astNodes(child);
  }
}

/// The name of the top-level function enclosing [node], if any.
String? topLevelFunction(AstNode node) {
  final function = node.thisOrAncestorOfType<FunctionDeclaration>();
  return function?.parent is CompilationUnit ? function?.name.lexeme : null;
}
