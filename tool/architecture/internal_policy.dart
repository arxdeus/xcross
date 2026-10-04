import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:meta/meta.dart';

import 'boundaries.dart';
import 'export_graph.dart';
import 'identity.dart';
import 'internal_roles.dart';

@internal
String canonicalLibraryUri(String source, {String? root}) {
  final uri = Uri.tryParse(source);
  if (uri?.scheme == 'package') return uri!.normalizePath().toString();
  final path = uri?.scheme == 'file'
      ? sourceFilePath(uri!.toFilePath(), root: root)
      : source;
  final pieces = path.split('/');
  if (pieces.length > 3 &&
      pieces[0] == 'packages' &&
      workspacePackages.contains(pieces[1]) &&
      pieces[2] == 'lib') {
    return 'package:${pieces[1]}/${pieces.skip(3).join('/')}';
  }
  if (!path.startsWith('/') && !path.startsWith('../')) {
    return 'workspace:$path';
  }
  return source;
}

@internal
Map<String, (AstNode, Element?)> declarationIdentities(CompilationUnit unit) {
  final result = <String, (AstNode, Element?)>{};
  for (final declaration in unit.declarations) {
    if (declaration is TopLevelVariableDeclaration) {
      for (final variable in declaration.variables.variables) {
        result['TOP_LEVEL_VARIABLE:${variable.name.lexeme}'] = (
          variable,
          variable.declaredFragment?.element,
        );
      }
      continue;
    }
    final (kind, name, element) = switch (declaration) {
      ClassDeclaration() => (
        'CLASS',
        declaration.namePart.typeName.lexeme,
        declaration.declaredFragment?.element,
      ),
      ClassTypeAlias() => (
        'CLASS',
        declaration.name.lexeme,
        declaration.declaredFragment?.element,
      ),
      MixinDeclaration() => (
        'MIXIN',
        declaration.name.lexeme,
        declaration.declaredFragment?.element,
      ),
      EnumDeclaration() => (
        'ENUM',
        declaration.namePart.typeName.lexeme,
        declaration.declaredFragment?.element,
      ),
      ExtensionTypeDeclaration() => (
        'EXTENSION_TYPE',
        declaration.namePart.typeName.lexeme,
        declaration.declaredFragment?.element,
      ),
      ExtensionDeclaration() => (
        'EXTENSION',
        declaration.declaredFragment?.element.name ??
            declaration.name?.lexeme ??
            '@${declaration.declaredFragment?.element.firstFragment.offset ?? declaration.offset}',
        declaration.declaredFragment?.element,
      ),
      GenericTypeAlias() => (
        'TYPE_ALIAS',
        declaration.name.lexeme,
        declaration.declaredFragment?.element,
      ),
      FunctionDeclaration() => (
        declaration.propertyKeyword?.lexeme == 'get'
            ? 'GETTER'
            : declaration.propertyKeyword?.lexeme == 'set'
            ? 'SETTER'
            : 'FUNCTION',
        declaration.name.lexeme,
        declaration.declaredFragment?.element,
      ),
      _ => ('UNKNOWN', null, null),
    };
    if (name != null) result['$kind:$name'] = (declaration, element);
  }
  return result;
}

@internal
List<Violation> internalPolicyViolations(
  String path,
  CompilationUnit unit, {
  required String root,
  Map<String, Map<String, String>> roles = reviewedDeclarationRoles,
  Set<String> internalLibraries = reviewedInternalLibraries,
}) {
  final violations = <Violation>[];
  void reject(AstNode node, String rule, String detail) =>
      violations.add(Violation(path, rule, node.offset, detail));
  final library = unit.declaredFragment?.element;
  final uri = canonicalLibraryUri(library?.uri.toString() ?? path, root: root);
  final libraryInternal = library?.metadata.hasInternal ?? false;
  if (internalLibraries.contains(uri) && !libraryInternal) {
    reject(
      unit,
      'internal-library-annotation',
      'Reviewed owning source library requires resolved package:meta internal metadata',
    );
  }
  for (final entry in declarationIdentities(unit).entries) {
    final (node, element) = entry.value;
    final role = roles[uri]?[entry.key];
    final internal = element?.metadata.hasInternal ?? false;
    if (role == null) {
      reject(
        node,
        'annotation-role',
        'Missing reviewed declaration role: $uri#${entry.key}',
      );
    } else if (role == 'internal' && !internal) {
      reject(
        node,
        'internal-annotation',
        'Implementation declaration requires resolved package:meta internal metadata',
      );
    } else if (role == 'library-internal' &&
        (!internalLibraries.contains(uri) || !libraryInternal)) {
      reject(
        node,
        'internal-library-annotation',
        'Generated declaration requires its exact reviewed internal owning library',
      );
    } else if ({'public', 'fixture', 'entrypoint'}.contains(role) &&
        (internal || libraryInternal)) {
      reject(
        node,
        'public-internal',
        'Supported contract or entrypoint must not be package-internal',
      );
    } else if (!{
      'internal',
      'library-internal',
      'public',
      'fixture',
      'entrypoint',
      'private',
    }.contains(role)) {
      reject(node, 'annotation-role', 'Unknown reviewed role: $role');
    }
  }
  String owner(String libraryUri) {
    final uri = Uri.tryParse(libraryUri);
    if (uri?.scheme == 'package') return uri!.path.split('/').first;
    final pieces = libraryUri.replaceFirst('workspace:', '').split('/');
    return pieces.length > 1 && pieces[0] == 'packages'
        ? pieces[1]
        : 'workspace';
  }

  for (final node in astNodes(unit)) {
    if (node is! SimpleIdentifier ||
        node.thisOrAncestorOfType<Combinator>() != null) {
      continue;
    }
    final element = node.element?.baseElement.nonSynthetic;
    final targetLibrary = element?.library;
    if (element == null || targetLibrary == null) continue;
    final target = canonicalLibraryUri(
      targetLibrary.uri.toString(),
      root: root,
    );
    if (roles.containsKey(target) &&
        owner(target) != owner(uri) &&
        (element.metadata.hasInternal ||
            (element.enclosingElement?.metadata.hasInternal ?? false) ||
            targetLibrary.metadata.hasInternal)) {
      reject(
        node,
        'internal-use',
        'Foreign package uses an internal declaration or owning library',
      );
    }
  }
  for (final directive in unit.directives.whereType<ImportDirective>()) {
    for (final text in [
      directive.uri.stringValue,
      ...directive.configurations.map((c) => c.uri.stringValue),
    ]) {
      if (text == null) continue;
      final target = canonicalLibraryUri(
        resolveUri(path, text, root: root),
        root: root,
      );
      if (internalLibraries.contains(target) && owner(target) != owner(uri)) {
        reject(
          directive,
          'internal-library-use',
          'Foreign package imports an exact reviewed internal owning library',
        );
      }
    }
  }
  return violations;
}
