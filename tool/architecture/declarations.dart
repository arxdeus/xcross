import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:meta/meta.dart';

import 'boundaries.dart';
import 'dispatch_rules.dart';
import 'export_graph.dart';
import 'identity.dart';

@internal
List<Violation> sourcePolicyViolations(
  String path,
  CompilationUnit unit, {
  String? root,
}) {
  final result = <Violation>[];
  void reject(AstNode node, String rule, String detail) =>
      result.add(Violation(path, rule, node.offset, detail));
  String? owner(String candidate) {
    final parts = candidate.split('/');
    return parts.length > 2 &&
            parts[0] == 'packages' &&
            workspacePackages.contains(parts[1])
        ? parts[1]
        : null;
  }

  for (final declaration in unit.declarations) {
    final name = switch (declaration) {
      ClassDeclaration() => declaration.namePart.typeName.lexeme,
      ClassTypeAlias() => declaration.name.lexeme,
      MixinDeclaration() => declaration.name.lexeme,
      EnumDeclaration() => declaration.namePart.typeName.lexeme,
      ExtensionTypeDeclaration() => declaration.namePart.typeName.lexeme,
      _ => null,
    };
    if (name?.startsWith('_') ?? false) {
      reject(
        declaration,
        'private-type',
        'Class-like declarations must have public names',
      );
    }
  }
  for (final directive in unit.directives) {
    if (directive is ExportDirective) {
      reject(
        directive,
        'export-directive',
        'Owned Dart source must import actual declaration libraries',
      );
    }
    if (directive is NamespaceDirective) {
      for (final combinator in directive.combinators) {
        if (combinator is ShowCombinator) {
          reject(
            combinator,
            'show-combinator',
            'Import actual declarations without show filters',
          );
        }
        if (combinator is HideCombinator) {
          reject(
            combinator,
            'hide-combinator',
            'Resolve genuine collisions with import prefixes',
          );
        }
      }
    }
    final uris = <StringLiteral>[];
    if (directive is UriBasedDirective) uris.add(directive.uri);
    if (directive is NamespaceDirective) {
      uris.addAll(directive.configurations.map((c) => c.uri));
    }
    if (directive is PartOfDirective && directive.uri != null) {
      uris.add(directive.uri!);
    }
    for (final literal in uris) {
      final uri = literal.stringValue;
      if (uri == null) {
        reject(directive, 'source-uri', 'Source URI must be a valid literal');
        continue;
      }
      final destination = resolveUri(path, uri, root: root);
      if (destination.startsWith('invalid:')) {
        reject(
          directive,
          'source-uri',
          'Source URI escapes or has invalid ownership: $uri',
        );
      }
      final destinationOwner = owner(destination);
      if (destinationOwner != null &&
          destinationOwner != owner(path) &&
          destination.startsWith('packages/$destinationOwner/lib/src/')) {
        reject(
          directive,
          'cross-package-src',
          'Import the public declaration library, not another package implementation: $destination',
        );
      }
    }
  }
  final declaredOwners = unit.directives.whereType<PartOfDirective>().toList();
  if (partOwners.containsKey(path)) {
    if (declaredOwners.length != 1 ||
        declaredOwners.single.uri?.stringValue == null ||
        resolveUri(path, declaredOwners.single.uri!.stringValue!, root: root) !=
            partOwners[path]) {
      reject(unit, 'inventory', 'Part must bind its exact approved owner');
    }
  }
  final expectedParts = partOwners.entries
      .where((e) => e.value == path)
      .map((e) => e.key)
      .toSet();
  if (expectedParts.isNotEmpty) {
    final actualParts = unit.directives
        .whereType<PartDirective>()
        .map((d) => resolveUri(path, d.uri.stringValue ?? '', root: root))
        .toList();
    if (actualParts.length != expectedParts.length ||
        !actualParts.toSet().containsAll(expectedParts)) {
      reject(
        unit,
        'inventory',
        'Owner must declare all and only exact approved parts',
      );
    }
  }
  return result;
}

@internal
class DeclarationRules extends RecursiveAstVisitor<void> {
  final String path;
  final List<Violation> violations = [];
  static const services = {
    'Log',
    'ProcessRunner',
    'Downloader',
    'ProgressBar',
    'DarwinSdkRepository',
    'DarwinToolchainResolver',
    'XcrossRuntime',
    'XcrossRuntimeConfig',
    'HttpClient',
    'StreamLogOutput',
    'LogOutput',
    'NativeFileSystem',
    'WindowsFileSystem',
    'HostFileSystemInterface',
  };
  DeclarationRules(this.path);
  void reject(AstNode node, String rule, String detail) =>
      violations.add(Violation(path, rule, node.offset, detail));
  void publicName(AstNode node, String name) {
    if (name.startsWith('_')) {
      reject(
        node,
        'private-type',
        'Class-like declarations must have public names',
      );
    }
  }

  bool service(DartType? type) =>
      type is InterfaceType &&
      ((type.element.library.uri.toString().startsWith('package:http/') &&
              {'Client', 'BaseClient'}.contains(type.element.name)) ||
          type.element.allSupertypes.any(
            (t) =>
                t.element.library.uri.toString().startsWith('package:http/') &&
                {'Client', 'BaseClient'}.contains(t.element.name),
          ) ||
          services.contains(type.element.name) ||
          type.element.allSupertypes.any(
            (t) => services.contains(t.element.name),
          ) ||
          {
            'PlatformHostInterface',
            'WindowsHostInterface',
            'LinuxHostInterface',
            'MacOSHostInterface',
            'WindowsHost',
            'LinuxHost',
            'MacOSHost',
          }.contains(type.element.name));
  bool creation(Expression expression) {
    if (expression is InstanceCreationExpression) {
      return service(expression.staticType);
    }
    if (expression is MethodInvocation) {
      return service(expression.staticType) &&
          expression.methodName.element is ExecutableElement;
    }
    if (expression.staticType is! FunctionType ||
        !service((expression.staticType! as FunctionType).returnType)) {
      return false;
    }
    if (expression is ConstructorReference) return true;
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

  bool constructsService(AstNode node) =>
      astNodes(node).whereType<Expression>().any(creation);

  bool hostBound(DartType? type) {
    if (type is TypeParameterType) return hostBound(type.bound);
    return type is InterfaceType &&
        (type.element.name == 'PlatformHostInterface' ||
            type.element.allSupertypes.any(
              (t) => t.element.name == 'PlatformHostInterface',
            ));
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final element = node.element;
    if (element?.enclosingElement is LibraryElement &&
        (element?.library?.uri.toString().startsWith('package:http/') ??
            false) &&
        {
          'get',
          'post',
          'put',
          'patch',
          'delete',
          'head',
          'read',
          'readBytes',
          'runWithClient',
        }.contains(element?.name)) {
      reject(
        node,
        'ambient-network',
        'Top-level HTTP effect bypasses injected client',
      );
    }
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    final dispatch = DispatchRules(path);
    dispatch.inspect(node);
    violations.addAll(dispatch.violations);
    publicName(node, node.namePart.typeName.lexeme);
    if (node.namePart.typeName.lexeme == 'PlatformTargetInterface' ||
        (node.declaredFragment?.element.allSupertypes.any(
              (t) => t.element.name == 'PlatformTargetInterface',
            ) ??
            false)) {
      final type = node.declaredFragment?.element;
      final core = node.namePart.typeName.lexeme == 'PlatformTargetInterface';
      final arguments = core
          ? [
              for (final p
                  in node.namePart.typeParameters?.typeParameters ??
                      <TypeParameter>[])
                p.bound?.type,
            ]
          : [
              for (final supertype in type?.allSupertypes ?? <InterfaceType>[])
                if (supertype.element.name == 'PlatformTargetInterface')
                  ...supertype.typeArguments,
            ];
      if (arguments.isEmpty || arguments.any((t) => !hostBound(t))) {
        reject(
          node,
          'target-bound',
          'Target host type must have a resolved PlatformHostInterface bound',
        );
      }
    }
    super.visitClassDeclaration(node);
  }

  @override
  void visitClassTypeAlias(ClassTypeAlias node) {
    publicName(node, node.name.lexeme);
    super.visitClassTypeAlias(node);
  }

  @override
  void visitMixinDeclaration(MixinDeclaration node) {
    publicName(node, node.name.lexeme);
    super.visitMixinDeclaration(node);
  }

  @override
  void visitEnumDeclaration(EnumDeclaration node) {
    publicName(node, node.namePart.typeName.lexeme);
    super.visitEnumDeclaration(node);
  }

  @override
  void visitExtensionTypeDeclaration(ExtensionTypeDeclaration node) {
    publicName(node, node.namePart.typeName.lexeme);
    super.visitExtensionTypeDeclaration(node);
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    final element = node.declaredFragment?.element;
    final global = node.parent?.parent is TopLevelVariableDeclaration;
    final field = node.parent?.parent;
    if ((global || field is FieldDeclaration && field.isStatic) &&
        service(element?.type)) {
      reject(
        node,
        'global-service',
        'Session service must be constructor injected, not global/static',
      );
    }
    if (field is FieldDeclaration &&
        field.isStatic &&
        service(
          node
              .thisOrAncestorOfType<ClassDeclaration>()
              ?.declaredFragment
              ?.element
              .thisType,
        ) &&
        node.parent is VariableDeclarationList &&
        !(node.parent! as VariableDeclarationList).isConst &&
        !(node.parent! as VariableDeclarationList).isFinal) {
      reject(node, 'mutable-service-state', 'Mutable static service state');
    }
    if (field is FieldDeclaration &&
        !field.isStatic &&
        node.initializer != null &&
        constructsService(node.initializer!)) {
      reject(
        node,
        'hidden-di-default',
        'Instance field creates a hidden effectful dependency',
      );
    }
    super.visitVariableDeclaration(node);
  }

  @override
  void visitConstructorFieldInitializer(ConstructorFieldInitializer node) {
    if (constructsService(node.expression)) {
      reject(
        node,
        'hidden-di-default',
        'Constructor creates an effectful dependency rather than injecting it',
      );
    }
    if (astNodes(node.expression).whereType<BinaryExpression>().any(
      (e) => e.operator.lexeme == '??' && constructsService(e.rightOperand),
    )) {
      reject(
        node,
        'hidden-di-default',
        'Effectful dependency fallback must be supplied by composition',
      );
    }
    super.visitConstructorFieldInitializer(node);
  }

  @override
  void visitFormalParameterDefaultClause(FormalParameterDefaultClause node) {
    if (constructsService(node.value)) {
      reject(
        node,
        'hidden-di-default',
        'Default service instance must be supplied explicitly',
      );
    }
    super.visitFormalParameterDefaultClause(node);
  }
}
