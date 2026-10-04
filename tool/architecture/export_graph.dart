import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:meta/meta.dart';

@internal
String resolveUri(String path, String uri, {String? root}) {
  final parsed = Uri.tryParse(uri);
  if (parsed == null || parsed.hasQuery || parsed.hasFragment) {
    return 'invalid:$uri';
  }
  if (parsed.scheme == 'file') {
    if (parsed.host.isNotEmpty && parsed.host != 'localhost') {
      return 'invalid:$uri';
    }
    try {
      return sourceFilePath(parsed.normalizePath().toFilePath(), root: root);
    } on Object catch (error) {
      if (error is! ArgumentError) rethrow;
      return 'invalid:$uri';
    }
  }
  if (parsed.scheme == 'package') {
    final pieces = parsed.path.split('/');
    if (pieces.length < 2 || pieces.first.isEmpty) return 'invalid:$uri';
    final destination = Uri.parse(
      'packages/${pieces.first}/lib/',
    ).resolve(pieces.skip(1).join('/')).normalizePath().path;
    if (!destination.startsWith('packages/${pieces.first}/lib/')) {
      return 'invalid:$uri';
    }
    return destination;
  }
  if (parsed.hasScheme || parsed.hasAuthority || parsed.path.startsWith('/')) {
    return 'external:$uri';
  }
  final destination = Uri.parse(path).resolveUri(parsed).normalizePath().path;
  if (destination.startsWith('../')) return 'invalid:$uri';
  return destination;
}

@internal
String sourceFilePath(String absolute, {String? root}) {
  if (root == null) return absolute;
  final owner = Uri.directory(root).normalizePath();
  final source = Uri.file(absolute).normalizePath();
  return source.path.startsWith(owner.path)
      ? source.path.substring(owner.path.length)
      : absolute;
}

@internal
class ExportGraph {
  final Map<String, CompilationUnit> units;
  final String? root;
  ExportGraph(this.units, {this.root});
  String resolve(String path, String uri) => resolveUri(path, uri, root: root);
  Map<String, Set<Element>> filter(
    Map<String, Set<Element>> source,
    Iterable<Combinator> combinators,
  ) {
    final result = Map<String, Set<Element>>.of(source);
    for (final combinator in combinators) {
      if (combinator is ShowCombinator) {
        final names = combinator.shownNames.map((n) => n.name).toSet();
        result.removeWhere((name, _) => !names.contains(name));
      }
      if (combinator is HideCombinator) {
        final names = combinator.hiddenNames.map((n) => n.name).toSet();
        result.removeWhere((name, _) => names.contains(name));
      }
    }
    return result;
  }

  Map<String, Set<Element>> names(String path, [Set<String>? visited]) {
    final seen = {...?visited};
    if (!seen.add(path)) return {};
    final unit = units[path];
    final library = unit?.declaredFragment?.element;
    if (unit == null || library == null) return {};
    final result = <String, Set<Element>>{};
    for (final element in <Element>[
      ...library.classes,
      ...library.enums,
      ...library.mixins,
      ...library.typeAliases,
      ...library.extensionTypes,
      ...library.extensions,
      ...library.topLevelFunctions,
      ...library.topLevelVariables,
      ...library.getters,
      ...library.setters,
    ]) {
      final name = element.name;
      if (name != null && !name.startsWith('_')) {
        result.putIfAbsent(name, () => {}).add(element);
      }
    }
    for (final directive in unit.directives.whereType<ExportDirective>()) {
      for (final uri in [
        directive.uri.stringValue,
        ...directive.configurations.map((c) => c.uri.stringValue),
      ]) {
        if (uri == null) continue;
        final destination = resolve(path, uri);
        final exported = filter(
          names(destination, seen),
          directive.combinators,
        );
        for (final entry in exported.entries) {
          result.putIfAbsent(entry.key, () => {}).addAll(entry.value);
        }
      }
    }
    return result;
  }

  Set<String> destinations(String source, String uri, AstNode node) {
    final path = resolve(source, uri);
    final combinators = node is NamespaceDirective
        ? node.combinators
        : <Combinator>[];
    if (units.containsKey(path)) {
      final visible = filter(names(path), combinators);
      return {
        for (final values in visible.values)
          for (final element in values)
            if (element.library != null)
              resolve(source, element.library!.uri.toString()),
      };
    }
    if (node is ImportDirective && uri == node.uri.stringValue) {
      return {
        for (final element
            in node.libraryImport?.namespace.definedNames2.values ??
                <Element>[])
          if (element.library != null)
            resolve(source, element.library!.uri.toString()),
      };
    }
    return {};
  }
}
