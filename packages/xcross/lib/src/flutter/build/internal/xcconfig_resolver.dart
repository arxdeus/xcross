import 'dart:io';

import 'package:path/path.dart' as p;

/// Resolves one Xcode build configuration in its textual include order.
abstract final class XcconfigResolver {
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
    final evaluation = _XcconfigEvaluation(
      configuration: configuration,
      sdk: sdk,
      arch: arch,
      defaults: defaults,
      overrides: overrides,
    );
    for (final line in _logicalLines(text.split('\n'))) {
      evaluation.apply(line);
    }
    return evaluation.resolved();
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
    final evaluation = _XcconfigEvaluation(
      configuration: configuration,
      sdk: sdk,
      arch: arch,
      defaults: defaults,
      overrides: overrides,
    );
    final reader = _XcconfigFileReader(evaluation);
    for (final path in paths) {
      await reader.read(path, optional: true);
    }
    return evaluation.resolved();
  }

  /// Join Xcode's backslash-continued physical lines before parsing settings.
  static Iterable<String> _logicalLines(Iterable<String> lines) sync* {
    final comments = _XcconfigComments();
    var pending = '';
    for (final raw in lines) {
      final line = comments.strip(raw).trimRight();
      if (_endsWithContinuation(line)) {
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

  /// An odd number of trailing backslashes leaves the last one unescaped,
  /// which continues the setting on the next physical line.
  static bool _endsWithContinuation(String line) {
    var trailingBackslashes = 0;
    for (
      var index = line.length - 1;
      index >= 0 && line[index] == r'\';
      index--
    ) {
      trailingBackslashes++;
    }
    return trailingBackslashes.isOdd;
  }
}

/// Reads xcconfig files depth-first, evaluating each `#include` at the point
/// where it appears and rejecting include cycles.
final class _XcconfigFileReader {
  _XcconfigFileReader(this._evaluation);

  static final _include = RegExp(
    r'^#include(\?)?\s+(?:"([^"]+)"|<([^>]+)>)\s*$',
  );

  final _XcconfigEvaluation _evaluation;
  final _activeFiles = <String>{};

  Future<void> read(String path, {required bool optional}) async {
    final file = File(path);
    if (!file.existsSync()) {
      if (optional) return;
      throw FormatException('Required xcconfig include not found: $path');
    }
    final resolved = p.normalize(file.absolute.path);
    if (!_activeFiles.add(resolved)) {
      throw FormatException('xcconfig include cycle at $resolved');
    }
    try {
      final lines = await file.readAsLines();
      for (final line in XcconfigResolver._logicalLines(lines)) {
        final include = _include.firstMatch(line);
        if (include == null) {
          _evaluation.apply(line);
          continue;
        }
        final includedPath = include[2] ?? include[3];
        await read(
          p.normalize(p.join(p.dirname(resolved), includedPath)),
          optional: include[1] == '?',
        );
      }
    } finally {
      _activeFiles.remove(resolved);
    }
  }
}

/// How specifically a conditional assignment matched the current build.
typedef _Specificity = ({int conditions, int literalCharacters});

/// Accumulates assignments for one configuration/SDK/architecture triple.
final class _XcconfigEvaluation {
  _XcconfigEvaluation({
    required this.configuration,
    required this.sdk,
    required this.arch,
    required this.defaults,
    required this.overrides,
  });

  static final _variable = RegExp(r'\$\(([^)]+)\)|\$\{([^}]+)\}');

  // The selector may itself contain '='. Match the complete key and its
  // selectors before splitting off the assignment value.
  static final _assignment = RegExp(
    r'^([A-Za-z_][A-Za-z_0-9.]*)(\s*(?:\[[^\]]+\])*)\s*=\s*(.*)$',
  );
  static final _qualifier = RegExp(r'\[([^\]]+)\]');

  final String configuration;
  final String sdk;
  final String arch;
  final Map<String, String> defaults;
  final Map<String, String> overrides;

  final _values = <String, String>{};
  final _specificities = <String, _Specificity>{};

  void apply(String raw) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('//') || line.startsWith('#')) return;
    final assignment = _assignment.firstMatch(line);
    if (assignment == null) {
      throw FormatException('Unsupported xcconfig assignment: $line');
    }
    final key = assignment[1]!;
    final specificity = _matchQualifiers(assignment[2]!);
    if (specificity == null || _isOutranked(key, specificity)) return;

    final inherited = _values[key] ?? defaults[key] ?? '';
    final assigned = assignment[3]!
        .replaceAll(r'$(inherited)', inherited)
        .replaceAll(r'${inherited}', inherited);
    // Bind references already available at this point in the include stream.
    // Unknown forward references remain for the final resolution pass.
    _values[key] = _expandAvailable(assigned, <String>{});
    _specificities[key] = specificity;
  }

  /// Specificity of the `[kind=pattern]` qualifiers in [head], or null when
  /// any qualifier does not match the current build.
  _Specificity? _matchQualifiers(String head) {
    var conditions = 0;
    var literalCharacters = 0;
    for (final match in _qualifier.allMatches(head)) {
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
      if (!_globMatches(pattern, actual)) return null;
      conditions++;
      literalCharacters += pattern.replaceAll('*', '').length;
    }
    return (conditions: conditions, literalCharacters: literalCharacters);
  }

  static bool _globMatches(String pattern, String actual) => RegExp(
    '^${RegExp.escape(pattern).replaceAll(r'\*', '.*')}\$',
    caseSensitive: false,
  ).hasMatch(actual);

  /// A matching conditional value outranks the unconditional value even if
  /// the latter appears later. Equal conditions retain last-assignment order.
  bool _isOutranked(String key, _Specificity candidate) {
    final previous = _specificities[key];
    if (previous == null) return false;
    return candidate.conditions < previous.conditions ||
        (candidate.conditions == previous.conditions &&
            candidate.literalCharacters < previous.literalCharacters);
  }

  String _expandAvailable(String value, Set<String> stack) =>
      value.replaceAllMapped(_variable, (match) {
        final reference = match[1] ?? match[2]!;
        final current =
            overrides[reference] ?? _values[reference] ?? defaults[reference];
        if (current == null) return match[0]!;
        if (!stack.add(reference)) {
          throw FormatException('xcconfig variable cycle: $reference');
        }
        try {
          return _expandAvailable(current, stack);
        } finally {
          stack.remove(reference);
        }
      });

  /// Final values for every assigned key plus all overrides, with remaining
  /// forward references resolved against the complete setting set.
  Map<String, String> resolved() {
    final expanded = _expandValues({...defaults, ..._values, ...overrides});
    return {for (final key in _values.keys) key: expanded[key]!, ...overrides};
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
