import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:meta/meta.dart';

import 'export_graph.dart';
import 'identity.dart';

@internal
class NativeSafety {
  final String path;
  final String? root;
  NativeSafety(this.path, {this.root});
  static const loaders = {
    'packages/apple_developer_kit/lib/src/host/linux/adi/linux_native_library_loader.dart':
        (
          'LinuxNativeLibraryLoader',
          'LinuxMemoryAllocator',
          {'linuxX64', 'linuxArm64'},
        ),
    'packages/apple_developer_kit/lib/src/host/macos/adi/macos_native_library_loader.dart':
        (
          'MacOSNativeLibraryLoader',
          'MacOSMemoryAllocator',
          {'macosX64', 'macosArm64'},
        ),
    'packages/apple_developer_kit/lib/src/host/windows/adi/loader/loader_windows.dart':
        (
          'WindowsNativeLibraryLoader',
          'WindowsMemoryAllocator',
          {'windowsX64', 'windowsArm64'},
        ),
  };
  bool scoped(AstNode node) =>
      loaders.containsKey(path) &&
      node.thisOrAncestorOfType<ClassDeclaration>()?.namePart.typeName.lexeme ==
          loaders[path]!.$1 &&
      node.thisOrAncestorOfType<FunctionExpression>() == null &&
      node.thisOrAncestorOfType<FunctionDeclaration>() == null;
  bool abiCurrent(AstNode node) =>
      node is SimpleIdentifier &&
      node.element?.library?.uri.toString() == 'dart:ffi' &&
      node.element?.enclosingElement?.name == 'Abi' &&
      node.element?.name == 'current';
  bool allocationBranch(AstNode node) {
    if (!scoped(node) ||
        node.thisOrAncestorOfType<MethodDeclaration>()?.name.lexeme !=
            '_createAllocator') {
      return false;
    }
    if (node is! SwitchExpression || node.cases.length != 2) return false;
    final constants = {
      for (final id in astNodes(
        node.cases.first.guardedPattern.pattern,
      ).whereType<SimpleIdentifier>())
        if (id.element?.library?.uri.toString() == 'dart:ffi' &&
            id.element?.enclosingElement?.name == 'Abi')
          id.element?.name,
    };
    final expected = loaders[path]!.$3;
    if (constants.length != expected.length ||
        !constants.containsAll(expected)) {
      return false;
    }
    final creation = node.cases.first.expression;
    final expression = node.expression;
    return expression is InstanceCreationExpression &&
        expression.constructorName.name?.name == 'current' &&
        expression.staticType is InterfaceType &&
        (expression.staticType! as InterfaceType).element.library.uri
                .toString() ==
            'dart:ffi' &&
        astNodes(expression).whereType<SimpleIdentifier>().any(abiCurrent) &&
        creation is InstanceCreationExpression &&
        creation.argumentList.arguments.isEmpty &&
        (creation.staticType is InterfaceType &&
            (creation.staticType! as InterfaceType).element.name ==
                loaders[path]!.$2) &&
        node.cases.last.expression is ThrowExpression;
  }

  bool read(SimpleIdentifier node) {
    if (!scoped(node) || !abiCurrent(node)) return false;
    final method = node.thisOrAncestorOfType<MethodDeclaration>();
    if (method?.name.lexeme == '_createAllocator') {
      final selection = node.thisOrAncestorOfType<SwitchExpression>();
      if (selection != null) return allocationBranch(selection);
      final condition = node.thisOrAncestorOfType<IfStatement>();
      if (condition != null && condition.expression is BinaryExpression) {
        final binary = condition.expression as BinaryExpression;
        final constants = astNodes(binary)
            .whereType<SimpleIdentifier>()
            .where(
              (id) =>
                  id.element?.library?.uri.toString() == 'dart:ffi' &&
                  id.element?.enclosingElement?.name == 'Abi' &&
                  id.element?.name != 'current',
            )
            .toList();
        return binary.operator.lexeme == '!=' &&
            constants.length == 1 &&
            loaders[path]!.$3.contains(constants.single.element?.name) &&
            astNodes(
              condition.thenStatement,
            ).whereType<ThrowExpression>().isNotEmpty &&
            astNodes(condition.thenStatement)
                .whereType<MethodInvocation>()
                .every((call) => call.methodName.name == 'current');
      }
      return false;
    }
    final constructor = node.thisOrAncestorOfType<ConstructorDeclaration>();
    if (constructor == null || loaders[path]!.$3.length == 1) return false;
    final AstNode? call =
        node.thisOrAncestorOfType<InstanceCreationExpression>() ??
        node.thisOrAncestorOfType<MethodInvocation>();
    final arguments = call?.parent;
    final outer = arguments?.parent;
    if (path ==
            'packages/apple_developer_kit/lib/src/host/windows/adi/loader/loader_windows.dart' &&
        arguments is ArgumentList &&
        arguments.arguments.length == 1 &&
        outer is InstanceCreationExpression &&
        outer.staticType is InterfaceType &&
        (outer.staticType! as InterfaceType).element.name == 'WindowsAdiAbi' &&
        outer.constructorName.name?.name == 'forAbi' &&
        resolveUri(
              path,
              (outer.staticType! as InterfaceType).element.library.uri
                  .toString(),
              root: root,
            ) ==
            'packages/apple_developer_kit/lib/src/host/windows/adi/loader/internal/windows/windows_adi_abi.dart') {
      return true;
    }
    return arguments is ArgumentList &&
        arguments.arguments.length == 1 &&
        outer is MethodInvocation &&
        outer.methodName.element?.enclosingElement?.name == 'AdiArchitecture' &&
        outer.methodName.name == 'forAbi' &&
        resolveUri(
              path,
              outer.methodName.element?.library?.uri.toString() ?? '',
              root: root,
            ) ==
            'packages/apple_developer_kit/lib/src/shared/adi/adi_architecture.dart';
  }
}
