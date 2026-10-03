import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

import 'declarations.dart';
import 'dependencies.dart';
import 'export_graph.dart';
import 'identity.dart';
import 'inventory.dart';
import 'native_rules.dart';
import 'native_safety.dart';

class Guard extends RecursiveAstVisitor<void> {
  final String path;
  final IdentityAnalysis identity;
  final Classification classification;
  final DependencyRules dependencies;
  final List<Violation> violations = [];
  final Set<int> selections = {};
  late final native = NativeRules(path, identity);
  Guard(this.path, this.identity, ExportGraph exports)
    : classification = classify(path),
      dependencies = DependencyRules(path, exports);
  void reject(AstNode node, String rule, String detail) =>
      violations.add(Violation(path, rule, node.offset, detail));
  bool get sourceInspection => architectureSources.contains(path);
  bool get concreteHost => classification.host != 'shared';
  bool supportsArchitecture(Set<String> kind) =>
      concreteHost && kind.length == 1 && kind.contains('architecture');
  bool validation(AstNode body) => body is Block
      ? body.statements.isNotEmpty && body.statements.every(validation)
      : body is ExpressionStatement && body.expression is ThrowExpression ||
            body is ReturnStatement && body.expression is BooleanLiteral;
  bool pureMetadata(Expression value) =>
      value is SimpleStringLiteral ||
      value is AdjacentStrings && value.strings.every(pureMetadata) ||
      value is IntegerLiteral ||
      value is DoubleLiteral ||
      value is BooleanLiteral ||
      value is NullLiteral ||
      value is ThrowExpression ||
      value is ConditionalExpression &&
          pureMetadata(value.thenExpression) &&
          pureMetadata(value.elseExpression);
  bool metadataReturn(AstNode body) => body is Block
      ? body.statements.length == 1 && metadataReturn(body.statements.single)
      : body is ReturnStatement &&
            body.expression != null &&
            pureMetadata(body.expression!);
  bool sdkOptions(AstNode condition) =>
      condition is ListLiteral &&
      condition.constKeyword != null &&
      condition.elements.length == 2 &&
      condition.elements.every(
        (value) =>
            value is InstanceCreationExpression &&
            value.argumentList.arguments.isEmpty &&
            value.staticType is InterfaceType &&
            {
              'IPhoneBuildPlatform',
              'SimulatorBuildPlatform',
            }.contains((value.staticType! as InterfaceType).element.name) &&
            (value.staticType! as InterfaceType).element.allSupertypes.any(
              (type) => type.element.name == 'IosBuildPlatformInterface',
            ),
      );
  void branch(AstNode node, AstNode condition, AstNode? body) {
    if (sourceInspection) return;
    final kind = identity.control(condition);
    if (kind.isEmpty) return;
    if (NativeSafety(path).allocationBranch(node)) return;
    if (supportsArchitecture(kind) &&
        body != null &&
        (validation(body) || metadataReturn(body))) {
      return;
    }
    if (supportsArchitecture(kind) &&
        node is SwitchExpression &&
        node.cases.every((c) => pureMetadata(c.expression))) {
      return;
    }
    if (supportsArchitecture(kind) &&
        node is ConditionalExpression &&
        pureMetadata(node.thenExpression) &&
        pureMetadata(node.elseExpression)) {
      return;
    }
    if (path ==
            'packages/xcross/lib/src/host/macos/compose/macos_compose_host.dart' &&
        node
                .thisOrAncestorOfType<ClassDeclaration>()
                ?.namePart
                .typeName
                .lexeme ==
            'MacOSComposeHost' &&
        node.thisOrAncestorOfType<MethodDeclaration>()?.name.lexeme ==
            'supportsJavaArchitecture' &&
        node.thisOrAncestorOfType<FunctionExpression>() == null &&
        kind.length == 1 &&
        kind.contains('architecture') &&
        node is ConditionalExpression &&
        astNodes(node).whereType<MethodInvocation>().every(
          (call) =>
              {
                'isArm64Architecture',
                'isX64Architecture',
              }.contains(call.methodName.name) &&
              (call.methodName.element?.library?.uri.toString().endsWith(
                    '/host/shared/compose/posix_compose_host.dart',
                  ) ??
                  false),
        ) &&
        node.thenExpression.staticType?.isDartCoreBool == true &&
        node.elseExpression.staticType?.isDartCoreBool == true) {
      return;
    }
    final literalIdentity = astNodes(condition).whereType<StringLiteral>().any(
      (n) => IdentityAnalysis.labels.contains(n.stringValue),
    );
    if (kind.length == 1 &&
        kind.contains('target') &&
        !literalIdentity &&
        body != null &&
        validation(body)) {
      return;
    }
    final function = topFunction(node);
    final approved =
        (path == detector && function == 'detectPlatformHostSnapshot') ||
        (path == hostComposition && function == 'composeXcrossHost') ||
        (targetComposition.contains(path) &&
            function == 'composeBuildFeatures') ||
        (path == 'packages/xcross/lib/src/composition/xcrun_sdk.dart' &&
            function == 'parseXcrunSdkName' &&
            (sdkOptions(condition) || kind.contains('target')) &&
            !astNodes(condition).whereType<SimpleIdentifier>().any(
              (id) => identity
                  .member(id.element)
                  .any({'host', 'architecture'}.contains),
            )) ||
        nativeHooks.contains(path) &&
            {
              'main',
              '_buildWithSystemCc',
              'systemCompilerFlags',
            }.contains(function) &&
            native.hookControl(condition);
    if (approved) {
      selections.add(node.offset);
    } else {
      reject(
        node,
        'platform-branch',
        'Platform identity selects behavior outside explicit composition',
      );
    }
  }

  List<Violation> inspect(CompilationUnit unit) {
    if (classification.kind == 'unclassified') {
      reject(unit, 'inventory', 'Production path has no final classification');
    }
    if (generatedCompositionParts.containsKey(path)) {
      final parts = unit.directives.whereType<PartOfDirective>().toList();
      if (parts.length != 1 ||
          parts.single.uri?.stringValue == null ||
          resolveUri(path, parts.single.uri!.stringValue!) !=
              generatedCompositionParts[path]) {
        reject(
          unit,
          'inventory',
          'Generated parser part must bind its exact approved composition owner',
        );
      }
    }
    if (classification.kind == 'barrel' &&
        (unit.declarations.isNotEmpty ||
            unit.directives.any((d) => d is PartDirective))) {
      reject(unit, 'barrel', 'Public barrel contains implementation');
    }
    if (classification.kind == 'entrypoint' &&
        (unit.declarations.length > 2 || astNodes(unit).length > 150)) {
      reject(unit, 'entrypoint', 'Entrypoint must delegate composition');
    }
    for (final node in astNodes(unit)) {
      if (node is FormalParameter) {
        final element = node.declaredFragment?.element;
        if (element?.type.isDartCoreBool == true &&
            IdentityAnalysis.flags.contains(element?.name)) {
          reject(node, 'identity-bool', 'Platform identity boolean parameter');
        }
      }
    }
    unit.accept(this);
    final declarations = DeclarationRules(path);
    unit.accept(declarations);
    violations.addAll(declarations.violations);
    if ((path == hostComposition || targetComposition.contains(path)) &&
        selections.length > 1) {
      reject(
        unit,
        'selector-count',
        'Platform normalization must occur once at composition',
      );
    }
    return [...violations, ...dependencies.violations, ...native.violations];
  }

  bool platformClass(ClassDeclaration? node) =>
      node != null &&
      (IdentityAnalysis.types.contains(node.namePart.typeName.lexeme) ||
          node.declaredFragment?.element.allSupertypes.any(
                (t) => IdentityAnalysis.types.contains(t.element.name),
              ) ==
              true);
  bool analyzerType(Element? element) =>
      element?.library?.uri.toString().startsWith('package:analyzer/') ?? false;

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    native.inspect(node);
    if (node.parent is MethodInvocation &&
        node.name == 'accept' &&
        identity.platformType(
          (node.parent! as MethodInvocation).target?.staticType,
        )) {
      reject(node, 'accept', 'Platform accept dispatch is prohibited');
    }
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitNamedType(NamedType node) {
    final type = node.type;
    if (type is InterfaceType) {
      if (!analyzerType(type.element) &&
          (type.element.name?.contains('Visitor') ?? false) &&
          type.element.allSupertypes.any(
            (t) => IdentityAnalysis.types.contains(t.element.name),
          )) {
        reject(node, 'visitor', 'Platform visitor type');
      }
      dependencies.importEdge(node, type.element.library.uri.toString());
    }
    super.visitNamedType(node);
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    final names = astNodes(
      node,
    ).whereType<MethodDeclaration>().map((m) => m.name.lexeme).toSet();
    final visitNames = names
        .where(
          (n) => {
            'visitWindows',
            'visitLinux',
            'visitMacOS',
            'visitSimulator',
            'visitIPhone',
          }.any(n.startsWith),
        )
        .length;
    if (!sourceInspection &&
        ((platformClass(node) &&
                node.namePart.typeName.lexeme.contains('Visitor')) ||
            visitNames >= 2 ||
            node.namePart.typeName.lexeme.contains('HostVisitor') ||
            node.namePart.typeName.lexeme.contains('TargetVisitor'))) {
      reject(node, 'visitor', 'Platform visitor declaration');
    }
    super.visitClassDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    final platform = platformClass(
      node.thisOrAncestorOfType<ClassDeclaration>(),
    );
    if (node.name.lexeme == 'accept' && platform) {
      reject(node, 'visitor', 'Platform accept declaration');
    }
    final boolResult =
        node.declaredFragment?.element.returnType.isDartCoreBool == true ||
        node.body is ExpressionFunctionBody &&
            (node.body as ExpressionFunctionBody)
                    .expression
                    .staticType
                    ?.isDartCoreBool ==
                true;
    final kind = identity.returns(node.body);
    if (!sourceInspection &&
        boolResult &&
        !supportsArchitecture(kind) &&
        (kind.isNotEmpty ||
            IdentityAnalysis.flags.contains(node.name.lexeme))) {
      reject(node, 'identity-bool', 'Platform identity bool/getter');
    }
    if (platform &&
        (node.parameters?.parameters
                    .where(
                      (p) => p.declaredFragment?.element.type is FunctionType,
                    )
                    .length ??
                0) >=
            2) {
      reject(
        node,
        'callback-dispatch',
        'Host/target API takes per-platform callbacks',
      );
    }
    if (platform && node.name.lexeme == 'get' && node.typeParameters != null) {
      reject(node, 'service-locator', 'Generic platform service locator');
    }
    super.visitMethodDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    final kind = identity.returns(node.functionExpression.body);
    if (!sourceInspection &&
        node.declaredFragment?.element.returnType.isDartCoreBool == true &&
        kind.isNotEmpty &&
        !supportsArchitecture(kind)) {
      reject(node, 'identity-bool', 'Platform identity function/getter');
    }
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    final kind = identity.value(node.initializer);
    if (!sourceInspection &&
        node.declaredFragment?.element.type.isDartCoreBool == true &&
        !supportsArchitecture(kind) &&
        (kind.isNotEmpty ||
            IdentityAnalysis.flags.contains(node.name.lexeme))) {
      reject(node, 'identity-bool', 'Platform identity boolean');
    }
    super.visitVariableDeclaration(node);
  }

  @override
  void visitMapLiteralEntry(MapLiteralEntry node) {
    if (!sourceInspection &&
        identity.control(node.key).isNotEmpty &&
        (node.value.staticType is FunctionType ||
            node.value is FunctionExpression ||
            node.value is InstanceCreationExpression ||
            node.value is MethodInvocation)) {
      reject(node, 'platform-registry', 'Platform-keyed strategy registry');
    }
    super.visitMapLiteralEntry(node);
  }

  @override
  void visitIfStatement(IfStatement node) {
    branch(node, node.expression, node.thenStatement);
    if (node.caseClause != null) {
      branch(node, node.caseClause!.guardedPattern, node.thenStatement);
    }
    super.visitIfStatement(node);
  }

  @override
  void visitIfElement(IfElement node) {
    branch(node, node.expression, null);
    if (node.caseClause != null) {
      branch(node, node.caseClause!.guardedPattern, null);
    }
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

  void loop(AstNode node, ForLoopParts parts) {
    if (parts is ForParts && parts.condition != null) {
      branch(node, parts.condition!, null);
    }
    if (parts is ForEachParts) branch(node, parts.iterable, null);
  }

  @override
  void visitForStatement(ForStatement node) {
    loop(node, node.forLoopParts);
    super.visitForStatement(node);
  }

  @override
  void visitForElement(ForElement node) {
    loop(node, node.forLoopParts);
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

  @override
  void visitImportDirective(ImportDirective node) {
    dependencies.importEdge(node, node.uri.stringValue);
    for (final config in node.configurations) {
      dependencies.importEdge(node, config.uri.stringValue);
    }
    super.visitImportDirective(node);
  }

  @override
  void visitExportDirective(ExportDirective node) {
    dependencies.importEdge(node, node.uri.stringValue);
    for (final config in node.configurations) {
      dependencies.importEdge(node, config.uri.stringValue);
    }
    super.visitExportDirective(node);
  }

  @override
  void visitPartDirective(PartDirective node) {
    dependencies.importEdge(node, node.uri.stringValue);
    super.visitPartDirective(node);
  }
}
