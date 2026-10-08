/// Shared infrastructure for the architecture rules.
library;

import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/file_system/file_system.dart';

import 'package:repo_analyzer/src/conventions.dart';
import 'package:repo_analyzer/src/identity.dart';
import 'package:repo_analyzer/src/platform_types.dart';

/// Base class for every xcross architecture rule.
///
/// Subclasses decide which zones they apply to and inspect one compilation
/// unit at a time through [check].
abstract class ArchitectureRule extends AnalysisRule {
  ArchitectureRule(this.code, {required super.description})
    : super(name: code.lowerCaseName);

  /// The diagnostic this rule reports.
  final LintCode code;

  @override
  DiagnosticCode get diagnosticCode => code;

  /// Whether the rule applies to a file at [location].
  bool appliesTo(SourceLocation location);

  /// Inspects [unit] and reports violations.
  void check(CompilationUnit unit, RuleScope scope);

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    registry.addCompilationUnit(this, _UnitVisitor(this, context));
  }
}

/// Creates a warning-severity lint code.
LintCode warning(String name, String problem, [String? correction]) => LintCode(
  name,
  problem,
  correctionMessage: correction,
  severity: DiagnosticSeverity.WARNING,
);

final class _UnitVisitor extends SimpleAstVisitor<void> {
  _UnitVisitor(this.rule, this.context);

  final ArchitectureRule rule;
  final RuleContext context;

  @override
  void visitCompilationUnit(CompilationUnit node) {
    final scope = RuleScope.of(context, node);
    if (scope == null || scope.location.isGenerated) return;
    if (!rule.appliesTo(scope.location)) return;
    rule.check(node, scope);
  }
}

/// Everything a rule knows about the unit under inspection.
final class RuleScope {
  RuleScope._(this.context, this.location, this.packageRoot);

  static RuleScope? of(RuleContext context, CompilationUnit unit) {
    final file = context.currentUnit?.file ?? context.definingUnit.file;
    final root = context.package?.root.path;
    // Fixture packages nested under another package (for example
    // `test/fixtures/<plugin>/lib`) are data, not workspace code.
    if (root != null && _isNestedFixture(root)) return null;
    return RuleScope._(
      context,
      SourceLocation.of(file.path, packageRoot: root),
      root,
    );
  }

  final RuleContext context;
  final SourceLocation location;
  final String? packageRoot;

  static final Expando<IdentityAnalysis> _identities = Expando();
  static final Expando<ServiceInference> _services = Expando();

  /// Identity analysis shared by every rule for the current library.
  IdentityAnalysis get identity {
    final library = context.libraryElement;
    if (library == null) {
      return IdentityAnalysis(context.allUnits.map((u) => u.unit));
    }
    return _identities[library] ??= IdentityAnalysis(
      context.allUnits.map((u) => u.unit),
    );
  }

  /// Service inference shared by every rule for the current library.
  ServiceInference get services {
    final library = context.libraryElement;
    if (library == null) return ServiceInference();
    return _services[library] ??= ServiceInference();
  }

  /// Classifies the library [element] is declared in, if it belongs to this
  /// workspace.
  SourceLocation? locate(LibraryElement? library) {
    if (library == null) return null;
    final uri = library.uri;
    if (uri.scheme == 'dart') return null;
    final path = library.firstFragment.source.fullName;
    final workspace = workspaceRoot;
    if (workspace == null || !path.startsWith('$workspace/')) return null;
    if (uri.scheme == 'package') return SourceLocation.ofPackageUri(uri);
    final provider = context.definingUnit.file.provider;
    final owner = _packageRootOf(provider.getFile(path).parent);
    return SourceLocation.of(path, packageRoot: owner);
  }

  /// Root folder of the pub workspace containing the current package.
  String? get workspaceRoot {
    final root = packageRoot;
    if (root == null) return null;
    return _workspaceRoots[root] ??= _findWorkspaceRoot(
      context.definingUnit.file.provider.getFolder(root),
    );
  }

  static final Map<String, String> _workspaceRoots = {};

  static String _findWorkspaceRoot(Folder package) {
    for (Folder? folder = package; folder != null; folder = folder.parent) {
      final pubspec = folder.getFile('pubspec.yaml');
      if (pubspec.exists &&
          RegExp(
            '^workspace:',
            multiLine: true,
          ).hasMatch(pubspec.readAsStringSync())) {
        return folder.path;
      }
      if (folder.isRoot) break;
    }
    return package.path;
  }

  static bool _isNestedFixture(String root) {
    // The analyzed package itself lives under another package's `test/` or
    // `example/` directory (it has its own pubspec, so `root` is the fixture).
    final segments = root.replaceAll(r'\', '/').split('/');
    final parent = segments.lastIndexWhere(
      (s) => s == 'test' || s == 'example',
    );
    return parent >= 0 && parent < segments.length - 1;
  }

  static String? _packageRootOf(Folder start) {
    for (Folder? folder = start; folder != null; folder = folder.parent) {
      if (folder.getFile('pubspec.yaml').exists) {
        return folder.path;
      }
      if (folder.isRoot) break;
    }
    return null;
  }
}

/// Recursive visitor that funnels into a callback, used by rules that need
/// full-tree traversal with resolved elements.
final class TreeWalker extends GeneralizingAstVisitor<void> {
  TreeWalker(this.onNode);

  final void Function(AstNode node) onNode;

  @override
  void visitNode(AstNode node) {
    onNode(node);
    super.visitNode(node);
  }
}

/// Runs [onNode] for every node of [unit].
void walk(CompilationUnit unit, void Function(AstNode node) onNode) =>
    unit.accept(TreeWalker(onNode));

/// Re-exported helper so rules only need one import.
Iterable<AstNode> descendants(AstNode node) => astNodes(node);
