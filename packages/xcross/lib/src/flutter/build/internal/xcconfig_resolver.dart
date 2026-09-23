import 'dart:io';

import 'package:path/path.dart' as p;

/// Resolves one Xcode build configuration in its textual include order.
abstract final class XcconfigResolver {
  static final _variable = RegExp(r'\$\(([^)]+)\)|\$\{([^}]+)\}');

  /// Flutter's generated settings are a fallback only when there is no
  /// authored Debug configuration. A Debug file that includes Generated must
  /// evaluate that include exactly once, at the point where it appears.
  static Future<Map<String, String>> readDebugConfiguration({
    required String debugPath,
    required String generatedPath,
    String configuration = 'Debug',
    String sdk = 'iphoneos',
    String arch = 'arm64',
    Map<String, String> defaults = const {},
    Map<String, String> overrides = const {},
  }) => readFiles(
    [if (File(debugPath).existsSync()) debugPath else generatedPath],
    configuration: configuration,
    sdk: sdk,
    arch: arch,
    defaults: defaults,
    overrides: overrides,
  );

  static Map<String, String> parseText(
    String text, {
    String configuration = 'Debug',
    String sdk = 'iphoneos',
    String arch = 'arm64',
    Map<String, String> defaults = const {},
    Map<String, String> overrides = const {},
  }) {
    final values = <String, String>{};
    final priorities = <String, (int, int)>{};
    for (final line in _logicalLines(text.split('\n'))) {
      _applyAssignment(
        line,
        values,
        priorities,
        configuration,
        sdk,
        arch,
        defaults,
        overrides,
      );
    }
    return _resolvedValues(values, defaults, overrides);
  }

  /// Process each root and its required or optional includes in text order.
  static Future<Map<String, String>> readFiles(
    Iterable<String> paths, {
    String configuration = 'Debug',
    String sdk = 'iphoneos',
    String arch = 'arm64',
    Map<String, String> defaults = const {},
    Map<String, String> overrides = const {},
  }) async {
    final values = <String, String>{};
    final priorities = <String, (int, int)>{};
    final stack = <String>{};

    Future<void> read(String path, {required bool optional}) async {
      final file = File(path);
      if (!file.existsSync()) {
        if (optional) return;
        throw FormatException('Required xcconfig include not found: $path');
      }
      final resolved = p.normalize(file.absolute.path);
      if (!stack.add(resolved)) {
        throw FormatException('xcconfig include cycle at $resolved');
      }
      try {
        for (final line in _logicalLines(await file.readAsLines())) {
          final include = RegExp(
            r'^#include(\?)?\s+(?:"([^"]+)"|<([^>]+)>)\s*$',
          ).firstMatch(line);
          if (include != null) {
            await read(
              p.normalize(
                p.join(p.dirname(resolved), include[2] ?? include[3]),
              ),
              optional: include[1] == '?',
            );
          } else {
            _applyAssignment(
              line,
              values,
              priorities,
              configuration,
              sdk,
              arch,
              defaults,
              overrides,
            );
          }
        }
      } finally {
        stack.remove(resolved);
      }
    }

    for (final path in paths) {
      await read(path, optional: true);
    }
    return _resolvedValues(values, defaults, overrides);
  }

  /// Join Xcode's backslash-continued physical lines before parsing settings.
  static Iterable<String> _logicalLines(Iterable<String> lines) sync* {
    final comments = _XcconfigComments();
    var pending = '';
    for (final raw in lines) {
      final line = comments.strip(raw).trimRight();
      var trailingBackslashes = 0;
      for (
        var index = line.length - 1;
        index >= 0 && line[index] == r'\';
        index--
      ) {
        trailingBackslashes++;
      }
      if (trailingBackslashes.isOdd) {
        pending += '${line.substring(0, line.length - 1).trim()} ';
        continue;
      }
      yield (pending + line.trimLeft()).trim();
      pending = '';
    }
    if (pending.isNotEmpty) {
      throw const FormatException('Unterminated xcconfig line continuation');
    }
  }

  static void _applyAssignment(
    String raw,
    Map<String, String> values,
    Map<String, (int, int)> priorities,
    String configuration,
    String sdk,
    String arch,
    Map<String, String> defaults,
    Map<String, String> overrides,
  ) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('//') || line.startsWith('#')) return;
    // The selector may itself contain '='. Match the complete key and its
    // selectors before splitting off the assignment value.
    final assignment = RegExp(
      r'^([A-Za-z_][A-Za-z_0-9.]*)(\s*(?:\[[^\]]+\])*)\s*=\s*(.*)$',
    ).firstMatch(line);
    if (assignment == null) {
      throw FormatException('Unsupported xcconfig assignment: $line');
    }
    final key = assignment[1]!;
    final head = assignment[2]!;
    var conditionCount = 0;
    var literalCount = 0;
    for (final match in RegExp(r'\[([^\]]+)\]').allMatches(head)) {
      final qualifier = match[1]!;
      final eq = qualifier.indexOf('=');
      final kind = eq < 0 ? 'config' : qualifier.substring(0, eq);
      final pattern = eq < 0 ? qualifier : qualifier.substring(eq + 1);
      final actual = switch (kind.toLowerCase()) {
        'config' => configuration,
        'sdk' => sdk,
        'arch' => arch,
        _ => throw FormatException(
          'Unsupported xcconfig qualifier: $qualifier',
        ),
      };
      final expression = RegExp(
        '^${RegExp.escape(pattern).replaceAll(r'\*', '.*')}\$',
        caseSensitive: false,
      );
      if (!expression.hasMatch(actual)) return;
      conditionCount++;
      literalCount += pattern.replaceAll('*', '').length;
    }
    // A matching conditional value outranks the unconditional value even if
    // the latter appears later. Equal conditions retain last-assignment order.
    final previous = priorities[key];
    if (previous != null &&
        (conditionCount < previous.$1 ||
            (conditionCount == previous.$1 && literalCount < previous.$2))) {
      return;
    }
    final inherited = values[key] ?? defaults[key] ?? '';
    final assigned = assignment[3]!
        .replaceAll(r'$(inherited)', inherited)
        .replaceAll(r'${inherited}', inherited);
    // Bind references already available at this point in the include stream.
    // Unknown forward references remain for the final resolution pass.
    values[key] = _expandAvailable(
      assigned,
      values,
      defaults,
      overrides,
      <String>{},
    );
    priorities[key] = (conditionCount, literalCount);
  }

  static String _expandAvailable(
    String value,
    Map<String, String> values,
    Map<String, String> defaults,
    Map<String, String> overrides,
    Set<String> stack,
  ) => value.replaceAllMapped(_variable, (match) {
    final reference = match[1] ?? match[2]!;
    final current =
        overrides[reference] ?? values[reference] ?? defaults[reference];
    if (current == null) return match[0]!;
    if (!stack.add(reference)) {
      throw FormatException('xcconfig variable cycle: $reference');
    }
    try {
      return _expandAvailable(current, values, defaults, overrides, stack);
    } finally {
      stack.remove(reference);
    }
  });

  static Map<String, String> _resolvedValues(
    Map<String, String> values,
    Map<String, String> defaults,
    Map<String, String> overrides,
  ) {
    final expanded = _expandValues({...defaults, ...values, ...overrides});
    return {for (final key in values.keys) key: expanded[key]!, ...overrides};
  }

  static Map<String, String> _expandValues(Map<String, String> values) {
    final expanded = <String, String>{};
    String resolve(String key, Set<String> stack) {
      if (expanded[key] case final String cached) return cached;
      if (!stack.add(key)) {
        throw FormatException('xcconfig variable cycle: $key');
      }
      final value = values[key]!.replaceAllMapped(_variable, (match) {
        final reference = match[1] ?? match[2]!;
        return values.containsKey(reference)
            ? resolve(reference, stack)
            : match[0]!;
      });
      stack.remove(key);
      return expanded[key] = value;
    }

    for (final key in values.keys) {
      resolve(key, <String>{});
    }
    return expanded;
  }
}

/// Removes C-style comments without mistaking quoted values for comments.
/// The state belongs to one xcconfig file so a block may span several lines.
final class _XcconfigComments {
  bool _inBlock = false;

  String strip(String line) {
    final result = StringBuffer();
    var quoted = false;
    var escaped = false;
    for (var index = 0; index < line.length; index++) {
      final character = line[index];
      final next = index + 1 < line.length ? line[index + 1] : '';
      if (_inBlock) {
        if (character == '*' && next == '/') {
          _inBlock = false;
          index++;
        }
        continue;
      }
      if (!quoted && character == '/' && next == '*') {
        _inBlock = true;
        result.write(' ');
        index++;
        continue;
      }
      // A trailing line comment starts after whitespace. Keep unquoted URL
      // values such as https://example.invalid intact.
      if (!quoted &&
          character == '/' &&
          next == '/' &&
          (index == 0 || line[index - 1].trim().isEmpty)) {
        break;
      }
      result.write(character);
      if (character == '"' && !escaped) quoted = !quoted;
      escaped = character == r'\' && !escaped;
    }
    return result.toString();
  }
}
