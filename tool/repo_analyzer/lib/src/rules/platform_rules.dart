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
import 'package:analyzer/dart/element/type.dart';

import 'package:repo_analyzer/src/conventions.dart';
import 'package:repo_analyzer/src/identity.dart';
import 'package:repo_analyzer/src/platform_types.dart';
import 'package:repo_analyzer/src/rule_base.dart';

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
