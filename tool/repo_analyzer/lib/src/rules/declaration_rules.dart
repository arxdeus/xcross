/// Declaration hygiene, dependency injection, and visibility rules.
library;

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

import 'package:repo_analyzer/src/conventions.dart';
import 'package:repo_analyzer/src/platform_types.dart';
import 'package:repo_analyzer/src/rule_base.dart';

bool _owned(SourceLocation location) => location.zone != Zone.other;

/// Reports class-like declarations with private names.
final class PrivateTypeRule extends ArchitectureRule {
  PrivateTypeRule()
    : super(
        warning(
          'private_type',
          "Class-like declaration '{0}' must have a public name.",
          'Give it a public name and mark it @internal if it is not API.',
        ),
        description:
            'Classes, mixins, enums, and extension types are always public; '
            'visibility is expressed with @internal.',
      );

  @override
  bool appliesTo(SourceLocation location) => _owned(location);

  @override
  void check(CompilationUnit unit, RuleScope scope) {
    for (final declaration in unit.declarations) {
      final token = switch (declaration) {
        ClassDeclaration() => declaration.namePart.typeName,
        ClassTypeAlias() => declaration.name,
        MixinDeclaration() => declaration.name,
        EnumDeclaration() => declaration.namePart.typeName,
        ExtensionTypeDeclaration() => declaration.namePart.typeName,
        _ => null,
      };
      if (token != null && token.lexeme.startsWith('_')) {
        reportAtToken(token, arguments: [token.lexeme]);
      }
    }
  }
}

/// Reports export directives and show/hide combinators in owned code.
final class DirectImportRule extends ArchitectureRule {
  DirectImportRule()
    : super(
        warning(
          'direct_import',
          '{0}',
          'Import the declaring library directly, using a prefix to resolve '
              'genuine name collisions.',
        ),
        description:
            'Owned code imports actual declaration libraries: no export '
            'barrels and no show/hide filters.',
      );

  @override
  bool appliesTo(SourceLocation location) => _owned(location);

  @override
  void check(CompilationUnit unit, RuleScope scope) {
    for (final directive in unit.directives) {
      if (directive is ExportDirective) {
        reportAtToken(
          directive.exportKeyword,
          arguments: ['Export directives hide the declaring library.'],
        );
      }
      if (directive is NamespaceDirective) {
        for (final combinator in directive.combinators) {
          reportAtToken(
            combinator.keyword,
            arguments: [
              if (combinator is ShowCombinator)
                'Import declarations without show filters.'
              else
                'Resolve collisions with import prefixes, not hide.',
            ],
          );
        }
      }
    }
  }
}

/// Reports implementation declarations that are not marked `@internal`.
///
/// Visibility is derived from location instead of a reviewed registry:
/// * `lib/src/**`: every public top-level declaration is implementation and
///   must be `@internal`, unless its whole library is `@internal`.
/// * `test/**/*_test.dart`, `tool/**`, `hook/**`, `bin/**`: every public
///   top-level declaration except `main` is a local helper and must be
///   `@internal`. Test support libraries (`test/**` files that are not
///   `*_test.dart`) are shared fixtures and may stay public.
/// * `lib/**` outside `src/` is the supported API and needs no annotation.
final class MissingInternalRule extends ArchitectureRule {
  MissingInternalRule()
    : super(
        warning(
          'missing_internal',
          "Implementation declaration '{0}' must be annotated @internal.",
          "Add '@internal' from package:meta, or move the declaration out of "
              "'lib/src/' if it is supported API.",
        ),
        description:
            "Public top-level declarations under 'lib/src/', 'test/', "
            "'tool/', 'hook/', and 'bin/' must be @internal.",
      );

  @override
  bool appliesTo(SourceLocation location) =>
      location.isImplementation ||
      location.zone == Zone.test &&
          location.segments.last.endsWith('_test.dart') ||
      location.zone == Zone.tool ||
      location.zone == Zone.entrypoint;

  @override
  void check(CompilationUnit unit, RuleScope scope) {
    final library = scope.context.libraryElement;
    if (library?.metadata.hasInternal ?? false) return;
    final entrypointZone = !scope.location.isImplementation;
    void inspect(Token token, Element? element) {
      final name = token.lexeme;
      if (name.startsWith('_')) return;
      if (entrypointZone && name == 'main') return;
      if (element == null || element.metadata.hasInternal) return;
      reportAtToken(token, arguments: [name]);
    }

    for (final declaration in unit.declarations) {
      switch (declaration) {
        case TopLevelVariableDeclaration():
          for (final variable in declaration.variables.variables) {
            inspect(variable.name, variable.declaredFragment?.element);
          }
        case ClassDeclaration():
          inspect(
            declaration.namePart.typeName,
            declaration.declaredFragment?.element,
          );
        case ClassTypeAlias():
          inspect(declaration.name, declaration.declaredFragment?.element);
        case MixinDeclaration():
          inspect(declaration.name, declaration.declaredFragment?.element);
        case EnumDeclaration():
          inspect(
            declaration.namePart.typeName,
            declaration.declaredFragment?.element,
          );
        case ExtensionTypeDeclaration():
          inspect(
            declaration.namePart.typeName,
            declaration.declaredFragment?.element,
          );
        case ExtensionDeclaration():
          final name = declaration.name;
          if (name != null) {
            inspect(name, declaration.declaredFragment?.element);
          }
        case GenericTypeAlias():
          inspect(declaration.name, declaration.declaredFragment?.element);
        case FunctionTypeAlias():
          inspect(declaration.name, declaration.declaredFragment?.element);
        case FunctionDeclaration():
          inspect(declaration.name, declaration.declaredFragment?.element);
      }
    }
  }
}

/// Reports global or static session services.
final class GlobalServiceRule extends ArchitectureRule {
  GlobalServiceRule()
    : super(
        warning(
          'global_service',
          "'{0}' holds a session service in {1} state.",
          'Construct the service in composition and inject it through '
              'constructors.',
        ),
        description:
            'Effectful services (hosts, loggers, process runners, HTTP '
            'clients, effect ports) must not live in globals or statics.',
      );

  @override
  bool appliesTo(SourceLocation location) =>
      location.zone == Zone.library || location.zone == Zone.composition;

  @override
  void check(CompilationUnit unit, RuleScope scope) {
    final services = scope.services;
    walk(unit, (node) {
      if (node is! VariableDeclaration) return;
      final list = node.parent;
      final owner = list?.parent;
      final global = owner is TopLevelVariableDeclaration;
      final static = owner is FieldDeclaration && owner.isStatic;
      if (!global && !static) return;
      final element = node.declaredFragment?.element;
      if (services.isService(element?.type)) {
        reportAtToken(
          node.name,
          arguments: [node.name.lexeme, if (global) 'global' else 'static'],
        );
      } else if (static &&
          list is VariableDeclarationList &&
          !list.isConst &&
          !list.isFinal &&
          services.isService(
            node
                .thisOrAncestorOfType<ClassDeclaration>()
                ?.declaredFragment
                ?.element
                .thisType,
          )) {
        reportAtToken(
          node.name,
          arguments: [node.name.lexeme, 'mutable static'],
        );
      }
    });
  }
}

/// Reports services constructed inside the classes that use them.
final class HiddenDependencyRule extends ArchitectureRule {
  HiddenDependencyRule()
    : super(
        warning(
          'hidden_dependency',
          '{0} creates an effectful dependency instead of receiving it.',
          'Require the dependency (or a factory) as a constructor parameter '
              'and supply it from composition.',
        ),
        description:
            'Field initializers, constructor initializers, `??` fallbacks, '
            'and parameter defaults must not construct services.',
      );

  @override
  bool appliesTo(SourceLocation location) => location.isLayeredLibrary;

  @override
  void check(CompilationUnit unit, RuleScope scope) {
    final services = scope.services;
    final location = scope.location;
    // A concrete host is its own composition for collaborators that live in
    // the same host directory: Windows loaders may wire Windows allocators.
    bool allowed(DartType? type) {
      if (!location.concreteHost || type is! InterfaceType) return false;
      final owner = scope.locate(type.element.library);
      return owner != null &&
          owner.host == location.host &&
          owner.target == location.target;
    }

    walk(unit, (node) {
      if (node is VariableDeclaration) {
        final field = node.parent?.parent;
        final initializer = node.initializer;
        if (field is FieldDeclaration &&
            !field.isStatic &&
            initializer != null &&
            services.constructsIn(initializer, allowed: allowed)) {
          reportAtNode(initializer, arguments: ['Instance field']);
        }
      } else if (node is ConstructorFieldInitializer) {
        if (services.constructsIn(node.expression, allowed: allowed)) {
          reportAtNode(node, arguments: ['Constructor initializer']);
        }
      } else if (node is FormalParameterDefaultClause) {
        if (services.constructsIn(node.value, allowed: allowed)) {
          reportAtNode(node.value, arguments: ['Parameter default']);
        }
      }
    });
  }
}

/// Reports top-level `package:http` calls that bypass an injected client.
final class AmbientNetworkRule extends ArchitectureRule {
  AmbientNetworkRule()
    : super(
        warning(
          'ambient_network',
          "Top-level HTTP effect '{0}' bypasses an injected client.",
          'Call the method on an injected http.Client.',
        ),
        description: 'package:http top-level helpers create hidden clients.',
      );

  static const _effects = {
    'get',
    'post',
    'put',
    'patch',
    'delete',
    'head',
    'read',
    'readBytes',
    'runWithClient',
  };

  @override
  bool appliesTo(SourceLocation location) =>
      location.zone == Zone.library || location.zone == Zone.composition;

  @override
  void check(CompilationUnit unit, RuleScope scope) {
    walk(unit, (node) {
      if (node is! SimpleIdentifier) return;
      final element = node.element;
      if (element?.enclosingElement is LibraryElement &&
          (element?.library?.uri.toString().startsWith('package:http/') ??
              false) &&
          _effects.contains(element?.name)) {
        reportAtNode(node, arguments: [node.name]);
      }
    });
  }
}

/// Reports targets whose host type parameter is not bound to the host root.
final class TargetHostBoundRule extends ArchitectureRule {
  TargetHostBoundRule()
    : super(
        warning(
          'target_host_bound',
          "Target '{0}' must bind its host type to $platformHostRoot.",
          'Declare the type parameter as `T extends $platformHostRoot` and '
              'pass it through to $platformTargetRoot<T>.',
        ),
        description:
            'Every $platformTargetRoot implementation keeps a resolved '
            'host bound.',
      );

  @override
  bool appliesTo(SourceLocation location) => _owned(location);

  static bool _hostBound(DartType? type) {
    if (type is TypeParameterType) return _hostBound(type.bound);
    return isHostType(type);
  }

  @override
  void check(CompilationUnit unit, RuleScope scope) {
    for (final node in unit.declarations.whereType<ClassDeclaration>()) {
      final type = node.declaredFragment?.element;
      if (type == null || !isTargetElement(type)) continue;
      final core = type.name == platformTargetRoot;
      final arguments = core
          ? [for (final p in type.typeParameters) p.bound]
          : [
              for (final supertype in type.allSupertypes)
                if (supertype.element.name == platformTargetRoot)
                  ...supertype.typeArguments,
            ];
      if (arguments.isEmpty || !arguments.every(_hostBound)) {
        reportAtToken(node.namePart.typeName, arguments: [type.name ?? '']);
      }
    }
  }
}
