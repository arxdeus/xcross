import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:meta/meta.dart';

import 'boundaries.dart';
import 'export_graph.dart';
import 'identity.dart';
import 'native_safety.dart';

@internal
String? topFunction(AstNode node) {
  final function = node.thisOrAncestorOfType<FunctionDeclaration>();
  return function?.parent is CompilationUnit ? function?.name.lexeme : null;
}

@internal
class NativeRules {
  final String path;
  final IdentityAnalysis identity;
  final List<Violation> violations = [];
  final String? root;
  NativeRules(this.path, this.identity, {this.root});
  bool hookControl(AstNode condition) {
    var input = false;
    for (final node in astNodes(condition).whereType<SimpleIdentifier>()) {
      final element = node.element;
      final uri = element?.library?.uri.toString() ?? '';
      final alias = identity.aliases[element];
      final nativeInput =
          node.staticType is InterfaceType &&
          (node.staticType! as InterfaceType).element.library.uri
              .toString()
              .startsWith('package:code_assets/') &&
          {
            'OS',
            'Architecture',
          }.contains((node.staticType! as InterfaceType).element.name);
      if (alias != null && alias.isNotEmpty && !nativeInput) return false;
      if (identity.platformOwner(element) ||
          element?.enclosingElement?.name == 'NativeHostSnapshot' ||
          uri == 'dart:io' && element?.enclosingElement?.name == 'Platform') {
        return false;
      }
      if (uri.startsWith('package:code_assets/')) input = true;
      if (node.staticType is InterfaceType) {
        final type = (node.staticType! as InterfaceType).element;
        if (type.library.uri.toString().startsWith('package:code_assets/') &&
            {'OS', 'Architecture'}.contains(type.name)) {
          input = true;
        }
      }
    }
    return input;
  }

  bool approved(SimpleIdentifier node) {
    if (NativeSafety(path, root: root).read(node)) return true;
    final function = topFunction(node);
    final element = node.element;
    final owner = element?.enclosingElement?.name;
    final name = element?.name;
    final uri = element?.library?.uri.toString();
    if (path == detector && function == 'detectPlatformHostSnapshot') {
      return owner == 'Platform' &&
              ({
                    'environment',
                    'resolvedExecutable',
                    'localHostname',
                    'localeName',
                    'numberOfProcessors',
                    'operatingSystem',
                  }.contains(name) ||
                  name?.startsWith('is') == true) ||
          owner == 'Directory' && {'current', 'systemTemp'}.contains(name) ||
          owner == 'Abi' && name == 'current';
    }
    if (nativeHooks.contains(path)) {
      if (function == '_buildWithSystemCc' &&
          {'OS', 'Architecture'}.contains(owner) &&
          name == 'current') {
        return true;
      }
      if ({'_resolveSystemCc', 'resolveMacOSCompiler'}.contains(function) &&
          owner == 'Platform' &&
          name == 'environment') {
        return true;
      }
    }
    if (uri == 'dart:io' &&
        {'stdin', 'stdout', 'stderr'}.contains(name) &&
        detectorCallers.containsKey(path) &&
        detectorCallers[path] == function) {
      return true;
    }
    if (path == 'packages/xcross/tool/build_xcross.dart' &&
        function == 'main' &&
        owner == 'Directory' &&
        name == 'current') {
      return true;
    }
    final commandStreams = {
      'packages/xcross/tool/verify_flutter_notices.dart': {'stdout'},
      'packages/xcross/tool/swiftpm_binary_fixture.dart': {'stdout', 'stderr'},
    };
    if (function == 'main' &&
        uri == 'dart:io' &&
        (commandStreams[path]?.contains(name) ?? false)) {
      return true;
    }
    if ({
          'tool/architecture/check.dart',
          'tool/architecture/check_test.dart',
        }.contains(path) &&
        function == 'main' &&
        uri == 'dart:io' &&
        {'stdout', 'stderr'}.contains(name)) {
      return true;
    }
    if (path == 'tool/architecture/check.dart' &&
        function == 'main' &&
        owner == 'Directory' &&
        name == 'current') {
      return true;
    }
    if (path == 'tool/architecture/check_test.dart' &&
        function == 'main' &&
        (owner == 'Platform' && name == 'environment' ||
            owner == 'Directory' && name == 'systemTemp')) {
      return true;
    }
    return false;
  }

  void inspect(SimpleIdentifier node) {
    if (identity.runtimeAccess(node.element) && !approved(node)) {
      violations.add(
        Violation(
          path,
          'ambient-detection',
          node.offset,
          'Ambient native state or standard IO outside exact composition API purpose',
        ),
      );
    }
    final element = node.element;
    final uri = element?.library?.uri.toString() ?? '';
    if (node.thisOrAncestorOfType<Combinator>() == null &&
        resolveUri(path, uri, root: root) == detector &&
        (element?.name?.startsWith('detectPlatformHost') ?? false) &&
        !(detectorCallers.containsKey(path) &&
            detectorCallers[path] == topFunction(node))) {
      violations.add(
        Violation(
          path,
          'hidden-detection',
          node.offset,
          'Native detector call or tear-off outside exact startup symbol',
        ),
      );
    }
  }
}
