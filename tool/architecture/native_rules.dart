import 'package:analyzer/dart/ast/ast.dart';

import 'identity.dart';
import 'inventory.dart';

String? topFunction(AstNode node) {
  final function = node.thisOrAncestorOfType<FunctionDeclaration>();
  return function?.parent is CompilationUnit ? function?.name.lexeme : null;
}

class NativeRules {
  final String path;
  final IdentityAnalysis identity;
  final List<Violation> violations = [];
  NativeRules(this.path, this.identity);
  bool approved(SimpleIdentifier node) {
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
          name == 'current')
        return true;
      if ({'_resolveSystemCc', 'resolveMacOSCompiler'}.contains(function) &&
          owner == 'Platform' &&
          name == 'environment')
        return true;
    }
    if (uri == 'dart:io' &&
        {'stdin', 'stdout', 'stderr'}.contains(name) &&
        detectorCallers.containsKey(path) &&
        detectorCallers[path] == function)
      return true;
    if (path == 'packages/xcross/tool/build_xcross.dart' &&
        function == 'main' &&
        owner == 'Directory' &&
        name == 'current')
      return true;
    if ({
          'tool/architecture/check.dart',
          'tool/architecture/check_test.dart',
        }.contains(path) &&
        function == 'main' &&
        uri == 'dart:io' &&
        {'stdout', 'stderr'}.contains(name))
      return true;
    if (path == 'tool/architecture/check.dart' &&
        function == 'main' &&
        owner == 'Directory' &&
        name == 'current')
      return true;
    if (path == 'tool/architecture/check_test.dart' &&
        function == 'main' &&
        (owner == 'Platform' && name == 'environment' ||
            owner == 'Directory' && name == 'systemTemp'))
      return true;
    return false;
  }

  void inspect(SimpleIdentifier node) {
    if (identity.runtimeAccess(node.element) && !approved(node))
      violations.add(
        Violation(
          path,
          'ambient-detection',
          node.offset,
          'Ambient native state or standard IO outside exact composition API purpose',
        ),
      );
    final element = node.element;
    final uri = element?.library?.uri.toString() ?? '';
    if (uri.endsWith('/composition/native_host.dart') &&
        (element?.name?.startsWith('detectPlatformHost') ?? false) &&
        !(detectorCallers.containsKey(path) &&
            detectorCallers[path] == topFunction(node)))
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
