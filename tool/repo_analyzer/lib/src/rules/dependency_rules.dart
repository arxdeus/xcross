/// Rules for import edges between architectural zones.
library;

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';

import 'package:repo_analyzer/src/conventions.dart';
import 'package:repo_analyzer/src/rule_base.dart';

/// The libraries [directive] makes reachable, including every library that
/// contributes a name through re-exports.
Iterable<LibraryElement> _reachedLibraries(UriBasedDirective directive) sync* {
  LibraryElement? direct;
  Iterable<Element> names = const [];
  if (directive is ImportDirective) {
    direct = directive.libraryImport?.importedLibrary;
    names = directive.libraryImport?.namespace.definedNames2.values ?? const [];
  } else if (directive is ExportDirective) {
    direct = directive.libraryExport?.exportedLibrary;
    names = direct?.exportNamespace.definedNames2.values ?? const [];
  }
  if (direct != null) yield direct;
  final seen = <LibraryElement>{?direct};
  for (final element in names) {
    final library = element.library;
    if (library != null && seen.add(library)) yield library;
  }
}

/// Reports layered library code that imports a composition root.
final class CompositionEdgeRule extends ArchitectureRule {
  CompositionEdgeRule()
    : super(
        warning(
          'composition_edge',
          "Layered library code reaches composition library '{0}'.",
          'Depend on the shared contract and let composition inject the '
              'implementation.',
        ),
        description:
            'Only composition roots, entrypoints, and tools may import '
            "'lib/**/composition/' libraries.",
      );

  @override
  bool appliesTo(SourceLocation location) => location.isLayeredLibrary;

  @override
  void check(CompilationUnit unit, RuleScope scope) {
    for (final directive in unit.directives.whereType<NamespaceDirective>()) {
      for (final library in _reachedLibraries(directive)) {
        if (scope.locate(library)?.zone == Zone.composition) {
          reportAtNode(directive.uri, arguments: [library.uri]);
          break;
        }
      }
    }
  }
}

/// Reports shared code that reaches a concrete host or target.
final class ConcretePlatformEdgeRule extends ArchitectureRule {
  ConcretePlatformEdgeRule()
    : super(
        warning(
          'concrete_platform_edge',
          "Code owned by host '{0}'/target '{1}' reaches '{2}', owned by "
              "host '{3}'/target '{4}'.",
          'Import the shared contract. Only composition may wire concrete '
              'host/target implementations.',
        ),
        description:
            "Files may only import 'host/<os>/' and 'target/<device>/' "
            'libraries of their own host/target. Composition roots are exempt.',
      );

  @override
  bool appliesTo(SourceLocation location) => location.isLayeredLibrary;

  @override
  void check(CompilationUnit unit, RuleScope scope) {
    final source = scope.location;
    for (final directive in unit.directives.whereType<NamespaceDirective>()) {
      for (final library in _reachedLibraries(directive)) {
        final destination = scope.locate(library);
        if (destination == null) continue;
        final hostLeak =
            destination.concreteHost && destination.host != source.host;
        final targetLeak =
            destination.concreteTarget && destination.target != source.target;
        if (hostLeak || targetLeak) {
          reportAtNode(
            directive.uri,
            arguments: [
              source.host,
              source.target,
              library.uri,
              destination.host,
              destination.target,
            ],
          );
          break;
        }
      }
    }
  }
}

/// Reports library files outside the recognised layer layout.
final class LibraryLayoutRule extends ArchitectureRule {
  LibraryLayoutRule()
    : super(
        warning(
          'library_layout',
          "Library file is outside the layer layout: '{0}'.",
          "Place it under 'lib/[src/]<layer>/' where <layer> is composition, "
              'shared, host/<os>, or target/<device>.',
        ),
        description:
            'Every library file must live in a composition, shared, host, or '
            'target layer so its ownership can be derived from its path.',
      );

  @override
  bool appliesTo(SourceLocation location) =>
      location.zone == Zone.library || location.zone == Zone.composition;

  @override
  void check(CompilationUnit unit, RuleScope scope) {
    final location = scope.location;
    if (location.hasKnownLayer) return;
    final token = unit.beginToken;
    reportAtOffset(
      token.offset,
      token.length,
      arguments: [location.segments.join('/')],
    );
  }
}

/// Reports `bin/` entrypoints that do work instead of delegating.
final class ThinEntrypointRule extends ArchitectureRule {
  ThinEntrypointRule()
    : super(
        warning(
          'thin_entrypoint',
          'Entrypoint must delegate to a composition root.',
          "Move logic into 'lib/**/composition/' and call it from main.",
        ),
        description:
            "'bin/' files may declare at most two top-level declarations and "
            'stay small.',
      );

  static const maxNodes = 150;

  @override
  bool appliesTo(SourceLocation location) => location.zone == Zone.entrypoint;

  @override
  void check(CompilationUnit unit, RuleScope scope) {
    if (unit.declarations.length > 2 || descendants(unit).length > maxNodes) {
      final main = unit.declarations
          .whereType<FunctionDeclaration>()
          .where((d) => d.name.lexeme == 'main')
          .firstOrNull;
      if (main != null) {
        reportAtToken(main.name);
      } else {
        reportAtOffset(unit.offset, 0);
      }
    }
  }
}
