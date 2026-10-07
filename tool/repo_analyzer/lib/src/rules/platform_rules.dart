/// Rules that keep platform selection inside composition roots.
///
/// Layered library code (`lib/**` outside `composition/`) must not observe
/// which host or target it runs on. It receives already-selected platform
/// objects and calls polymorphic contracts on them. Composition roots
/// (`lib/**/composition/**`, `bin/`, `tool/`, `hook/`) are the only places
/// allowed to detect and select platforms.
library;

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

import '../conventions.dart';
import '../identity.dart';
import '../platform_types.dart';
import '../rule_base.dart';

bool _pureMetadata(Expression value) =>
    value is SimpleStringLiteral ||
    value is AdjacentStrings && value.strings.every(_pureMetadata) ||
    value is IntegerLiteral ||
    value is DoubleLiteral ||
    value is BooleanLiteral ||
    value is NullLiteral ||
    value is ThrowExpression ||
    value is ConditionalExpression &&
        _pureMetadata(value.thenExpression) &&
        _pureMetadata(value.elseExpression);

/// A selection result that does not dispatch behaviour: metadata, a throw, a
/// boolean answer, or an argument-less construction of a local helper.
bool _pureSelection(Expression value) =>
    _pureMetadata(value) ||
    value.staticType?.isDartCoreBool == true ||
    value is InstanceCreationExpression && value.argumentList.arguments.isEmpty;

bool _validation(AstNode body) => body is Block
    ? body.statements.isNotEmpty && body.statements.every(_validation)
    : body is ExpressionStatement && body.expression is ThrowExpression ||
          body is ReturnStatement && body.expression is BooleanLiteral;

bool _metadataReturn(AstNode body) => body is Block
    ? body.statements.length == 1 && _metadataReturn(body.statements.single)
    : body is ReturnStatement &&
          body.expression != null &&
          _pureMetadata(body.expression!);

/// Host-owned code may describe its own CPU architecture.
bool _architectureOnly(SourceLocation location, Set<String> kind) =>
    location.concreteHost &&
    kind.length == 1 &&
    kind.contains(kindArchitecture);

/// Reports platform identity that selects behaviour outside composition.
final class PlatformBranchRule extends ArchitectureRule {
  PlatformBranchRule()
    : super(
        warning(
          'platform_branch',
          'Platform identity selects behavior outside a composition root.',
          'Inject the selected host/target implementation from '
              "'lib/**/composition/' instead of branching on identity.",
        ),
        description:
            'Layered library code must not branch on host, target, or '
            'architecture identity.',
      );

  @override
  bool appliesTo(SourceLocation location) => location.isLayeredLibrary;

  @override
  void check(CompilationUnit unit, RuleScope scope) =>
      unit.accept(_BranchVisitor(this, scope));

  bool allowed(
    SourceLocation location,
    IdentityAnalysis identity,
    AstNode node,
    AstNode condition,
    AstNode? body,
  ) {
    final kind = identity.control(condition);
    if (kind.isEmpty) return true;
    if (_architectureOnly(location, kind)) {
      if (body != null && (_validation(body) || _metadataReturn(body))) {
        return true;
      }
      if (node is SwitchExpression &&
          node.cases.every((c) => _pureSelection(c.expression))) {
        return true;
      }
      if (node is ConditionalExpression &&
          _pureSelection(node.thenExpression) &&
          _pureSelection(node.elseExpression)) {
        return true;
      }
    }
    final literalIdentity = descendants(condition)
        .whereType<StringLiteral>()
        .any((n) => platformLabels.contains(n.stringValue));
    if (kind.length == 1 &&
        kind.contains(kindTarget) &&
        !literalIdentity &&
        body != null &&
        _validation(body)) {
      return true;
    }
    return false;
  }
}

final class _BranchVisitor extends RecursiveAstVisitor<void> {
  _BranchVisitor(this.rule, this.scope);

  final PlatformBranchRule rule;
  final RuleScope scope;

  void branch(AstNode node, AstNode condition, AstNode? body) {
    if (!rule.allowed(scope.location, scope.identity, node, condition, body)) {
      rule.reportAtNode(node is Statement ? condition : node);
    }
  }

  @override
  void visitIfStatement(IfStatement node) {
    branch(node, node.expression, node.thenStatement);
    final pattern = node.caseClause?.guardedPattern;
    if (pattern != null) branch(node, pattern, node.thenStatement);
    super.visitIfStatement(node);
  }

  @override
  void visitIfElement(IfElement node) {
    branch(node, node.expression, null);
    final pattern = node.caseClause?.guardedPattern;
    if (pattern != null) branch(node, pattern, null);
    super.visitIfElement(node);
  }

  @override
  void visitWhileStatement(WhileStatement node) {
    branch(node, node.condition, node.body);
    super.visitWhileStatement(node);
  }

  @override
  void visitDoStatement(DoStatement node) {
    branch(node, node.condition, node.body);
    super.visitDoStatement(node);
  }

  void _loop(AstNode node, ForLoopParts parts) {
    if (parts is ForParts && parts.condition != null) {
      branch(node, parts.condition!, null);
    }
    if (parts is ForEachParts) branch(node, parts.iterable, null);
  }

  @override
  void visitForStatement(ForStatement node) {
    _loop(node, node.forLoopParts);
    super.visitForStatement(node);
  }

  @override
  void visitForElement(ForElement node) {
    _loop(node, node.forLoopParts);
    super.visitForElement(node);
  }

  @override
  void visitConditionalExpression(ConditionalExpression node) {
    branch(node, node.condition, null);
    super.visitConditionalExpression(node);
  }

  @override
  void visitSwitchStatement(SwitchStatement node) {
    branch(node, node.expression, null);
    for (final member in node.members) {
      if (member is SwitchCase) branch(node, member.expression, null);
      if (member is SwitchPatternCase) {
        branch(node, member.guardedPattern, null);
      }
    }
    super.visitSwitchStatement(node);
  }

  @override
  void visitSwitchExpression(SwitchExpression node) {
    branch(node, node.expression, null);
    for (final member in node.cases) {
      branch(node, member.guardedPattern, null);
    }
    super.visitSwitchExpression(node);
  }
}

/// Reports booleans that encode platform identity.
final class PlatformIdentityBoolRule extends ArchitectureRule {
  PlatformIdentityBoolRule()
    : super(
        warning(
          'platform_identity_bool',
          'Boolean encodes platform identity outside a composition root.',
          'Model the difference as a capability on the injected platform '
              'contract instead of an identity flag.',
        ),
        description:
            'Layered library code must not expose or accept booleans that '
            'encode host/target identity (isWindows, isSimulator, ...).',
      );

  @override
  bool appliesTo(SourceLocation location) => location.isLayeredLibrary;

  @override
  void check(CompilationUnit unit, RuleScope scope) {
    final identity = scope.identity;
    final location = scope.location;
    bool rejected(Set<String> kind, String? name) =>
        !_architectureOnly(location, kind) &&
        (kind.isNotEmpty || isIdentityFlag(name));
    walk(unit, (node) {
      if (node is FormalParameter) {
        final element = node.declaredFragment?.element;
        if (element?.type.isDartCoreBool == true &&
            isIdentityFlag(element?.name)) {
          reportAtNode(node);
        }
      } else if (node is MethodDeclaration) {
        final element = node.declaredFragment?.element;
        final body = node.body;
        final boolResult =
            element?.returnType.isDartCoreBool == true ||
            body is ExpressionFunctionBody &&
                body.expression.staticType?.isDartCoreBool == true;
        if (boolResult && rejected(identity.returns(body), node.name.lexeme)) {
          reportAtToken(node.name);
        }
      } else if (node is FunctionDeclaration) {
        final kind = identity.returns(node.functionExpression.body);
        if (node.declaredFragment?.element.returnType.isDartCoreBool == true &&
            kind.isNotEmpty &&
            !_architectureOnly(location, kind)) {
          reportAtToken(node.name);
        }
      } else if (node is VariableDeclaration) {
        final element = node.declaredFragment?.element;
        if (element?.type.isDartCoreBool == true &&
            rejected(identity.value(node.initializer), node.name.lexeme)) {
          reportAtToken(node.name);
        }
      }
    });
  }
}

/// Reports platform-keyed strategy tables.
final class PlatformRegistryRule extends ArchitectureRule {
  PlatformRegistryRule()
    : super(
        warning(
          'platform_registry',
          'Platform-keyed strategy registry.',
          'Select the implementation once in composition and inject it.',
        ),
        description:
            'Maps from platform identity to behaviour are hidden platform '
            'branches.',
      );

  @override
  bool appliesTo(SourceLocation location) => location.isLayeredLibrary;

  @override
  void check(CompilationUnit unit, RuleScope scope) {
    final identity = scope.identity;
    walk(unit, (node) {
      if (node is MapLiteralEntry &&
          identity.control(node.key).isNotEmpty &&
          (node.value.staticType is FunctionType ||
              node.value is FunctionExpression ||
              node.value is InstanceCreationExpression ||
              node.value is MethodInvocation)) {
        reportAtNode(node);
      }
    });
  }
}

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

/// Reports ambient reads of native process/machine state.
final class AmbientPlatformStateRule extends ArchitectureRule {
  AmbientPlatformStateRule()
    : super(
        warning(
          'ambient_platform_state',
          "Ambient native state '{0}' read outside a composition root.",
          'Read it once in composition (or an entrypoint) and inject the '
              'value or a port.',
        ),
        description:
            'Layered library code must not read Platform.*, Directory.current, '
            'stdio, Abi.current, or code_assets OS/Architecture.current.',
      );

  @override
  bool appliesTo(SourceLocation location) => location.isLayeredLibrary;

  @override
  void check(CompilationUnit unit, RuleScope scope) {
    final location = scope.location;
    walk(unit, (node) {
      if (node is! SimpleIdentifier) return;
      final element = node.element;
      if (!IdentityAnalysis.isRuntimeAccess(element)) return;
      // Host-owned native code may read the architecture it was loaded on.
      if (location.concreteHost &&
          element?.enclosingElement?.name == 'Abi' &&
          element?.name == 'current') {
        return;
      }
      final owner = element?.enclosingElement;
      reportAtNode(
        node,
        arguments: [
          owner is LibraryElement ? node.name : '${owner?.name}.${node.name}',
        ],
      );
    });
  }
}

/// Reports calls to composition-owned platform detectors from library code.
final class HiddenPlatformDetectionRule extends ArchitectureRule {
  HiddenPlatformDetectionRule()
    : super(
        warning(
          'hidden_platform_detection',
          "Platform detector '{0}' used outside a composition root.",
          'Detect the platform once at startup and inject the result.',
        ),
        description:
            'detect* functions declared in composition libraries may only be '
            'called from composition roots and entrypoints.',
      );

  @override
  bool appliesTo(SourceLocation location) => location.isLayeredLibrary;

  @override
  void check(CompilationUnit unit, RuleScope scope) {
    walk(unit, (node) {
      if (node is! SimpleIdentifier ||
          node.thisOrAncestorOfType<Combinator>() != null) {
        return;
      }
      final element = node.element;
      if (element is! TopLevelFunctionElement ||
          !(element.name?.startsWith('detect') ?? false)) {
        return;
      }
      if (scope.locate(element.library)?.zone == Zone.composition) {
        reportAtNode(node, arguments: [node.name]);
      }
    });
  }
}

/// Reports direct acquisition of native resources in platform-neutral code.
final class NativeAcquisitionRule extends ArchitectureRule {
  NativeAcquisitionRule()
    : super(
        warning(
          'native_acquisition',
          "Native '{0}' acquisition in platform-neutral code.",
          'Acquire files, processes, sockets, and HTTP clients through an '
              'injected host port (for example HostFileSystemInterface).',
        ),
        description:
            "Code under 'shared/' and 'target/' must not construct File, "
            'Directory, Link, or HttpClient, nor call Process/Socket/'
            'FileSystemEntity statics.',
      );

  static const _constructors = {'File', 'Directory', 'Link', 'HttpClient'};
  static const _endpoints = {
    'Process': {'run', 'runSync', 'start'},
    'Socket': {'connect', 'startConnect'},
    'ServerSocket': {'bind'},
  };

  @override
  bool appliesTo(SourceLocation location) =>
      location.isLayeredLibrary &&
      (location.layer == 'shared' || location.layer == 'target');

  @override
  void check(CompilationUnit unit, RuleScope scope) {
    void constructor(AstNode node, ConstructorName name) {
      final element = name.element;
      final uri = element?.library.uri.toString();
      final owner = element?.enclosingElement.name;
      if ((uri == 'dart:io' || uri == 'dart:_http' && owner == 'HttpClient') &&
          _constructors.contains(owner)) {
        reportAtNode(node, arguments: ['$owner.${element?.name ?? 'new'}']);
      }
    }

    walk(unit, (node) {
      if (node is InstanceCreationExpression) {
        constructor(node, node.constructorName);
      } else if (node is ConstructorReference) {
        constructor(node, node.constructorName);
      } else if (node is SimpleIdentifier) {
        final element = node.element;
        if (element is ExecutableElement &&
            element is! ConstructorElement &&
            element.isStatic &&
            element.library.uri.toString() == 'dart:io') {
          final owner = element.enclosingElement?.name;
          if ({'FileSystemEntity', 'FileStat'}.contains(owner) ||
              _endpoints[owner]?.contains(element.name) == true) {
            reportAtNode(node, arguments: ['$owner.${element.name}']);
          }
        }
      }
    });
  }
}
