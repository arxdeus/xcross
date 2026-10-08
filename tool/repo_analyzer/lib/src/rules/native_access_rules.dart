/// Rules that keep native process, machine, and resource access inside
/// composition roots and injected host ports.
library;

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';

import 'package:repo_analyzer/src/conventions.dart';
import 'package:repo_analyzer/src/identity.dart';
import 'package:repo_analyzer/src/rule_base.dart';

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
          if (owner is LibraryElement)
            node.name
          else
            '${owner?.name}.${node.name}',
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
            'Directory, Link, or HttpClient, nor call Process, Socket, or '
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
