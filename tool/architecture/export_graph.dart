import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';

String resolveUri(String path, String uri) => uri.startsWith('file:')
    ? sourceFilePath(Uri.parse(uri).toFilePath())
    : uri.startsWith('package:')
    ? 'packages/${uri.substring(8).split('/').first}/lib/${uri.substring(8).split('/').skip(1).join('/')}'
    : Uri.parse(path).resolve(uri).normalizePath().path;

String sourceFilePath(String absolute) {
  for (final marker in ['/packages/', '/tool/']) {
    final index = absolute.lastIndexOf(marker);
    if (index >= 0) return absolute.substring(index + 1);
  }
  return absolute;
}

class ExportGraph {
  final Map<String, CompilationUnit> units;
  ExportGraph(this.units);
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
      if (name != null && !name.startsWith('_'))
        result.putIfAbsent(name, () => {}).add(element);
    }
    for (final directive in unit.directives.whereType<ExportDirective>()) {
      for (final uri in [
        directive.uri.stringValue,
        ...directive.configurations.map((c) => c.uri.stringValue),
      ]) {
        if (uri == null) continue;
        final destination = resolveUri(path, uri);
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
    final path = resolveUri(source, uri);
    final combinators = node is NamespaceDirective
        ? node.combinators
        : <Combinator>[];
    if (units.containsKey(path)) {
      final visible = filter(names(path), combinators);
      return {
        for (final values in visible.values)
          for (final element in values)
            if (element.library != null)
              resolveUri(source, element.library!.uri.toString()),
      };
    }
    if (node is ImportDirective && uri == node.uri.stringValue)
      return {
        for (final element
            in node.libraryImport?.namespace.definedNames2.values ??
                <Element>[])
          if (element.library != null)
            resolveUri(source, element.library!.uri.toString()),
      };
    return {};
  }
}
