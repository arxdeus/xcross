import 'dart:convert';

const String xcrossLaunchName = 'xcross: iOS device';
const String dapPathSetting = 'dart.customFlutterDapPath';
const String dapPathValue = '.vscode/xcross_dap.dart';
const String promptErrorsSetting = 'dart.promptToRunIfErrors';

/// JSONC parse/merge helpers for VS Code launch.json / settings.json.
abstract final class VscodeJsonMerge {
  /// Strip JSONC sugar VS Code allows: `//` / `/* */` comments and trailing
  /// commas before `}` / `]`. Strings are left untouched.
  static String stripJsonc(String source) {
    final out = StringBuffer();
    var i = 0;
    while (i < source.length) {
      final c = source[i];
      if (c == '"') {
        i = _copyStringLiteral(source, i, out);
        continue;
      }
      if (_skipComment(source, i) case final afterComment?) {
        i = afterComment;
        continue;
      }
      if (c == ',') {
        final afterComma = _skipTrivia(source, i + 1);
        if (afterComma < source.length &&
            (source[afterComma] == '}' || source[afterComma] == ']')) {
          i = afterComma;
          continue;
        }
      }
      out.write(c);
      i++;
    }
    return out.toString();
  }

  /// Copy the string literal opening at [start] verbatim, escapes included,
  /// so that `//`, `/*` and `,` inside it survive. Returns the index just
  /// past the closing quote, or the end of input for an unterminated string.
  static int _copyStringLiteral(String source, int start, StringBuffer out) {
    out.write(source[start]);
    var i = start + 1;
    while (i < source.length) {
      final c = source[i];
      out.write(c);
      if (c == r'\' && i + 1 < source.length) {
        out.write(source[i + 1]);
        i += 2;
        continue;
      }
      i++;
      if (c == '"') return i;
    }
    return i;
  }

  /// Index just past the comment starting at [start], or null when [start]
  /// does not open one. A `//` comment stops *at* its newline so the line
  /// structure of the document is preserved.
  static int? _skipComment(String source, int start) {
    if (start + 1 >= source.length || source[start] != '/') return null;
    var i = start + 2;
    switch (source[start + 1]) {
      case '/':
        while (i < source.length && source[i] != '\n') {
          i++;
        }
        return i;
      case '*':
        while (i + 1 < source.length &&
            !(source[i] == '*' && source[i + 1] == '/')) {
          i++;
        }
        return i + 2 <= source.length ? i + 2 : source.length;
      default:
        return null;
    }
  }

  static bool _isSpace(String c) =>
      c == ' ' || c == '\t' || c == '\n' || c == '\r';

  /// Skip whitespace and comments; returns the index of the next real token.
  static int _skipTrivia(String source, int start) {
    var i = start;
    while (i < source.length) {
      if (_isSpace(source[i])) {
        i++;
        continue;
      }
      if (_skipComment(source, i) case final afterComment?) {
        i = afterComment;
        continue;
      }
      break;
    }
    return i;
  }

  /// Parse JSON or JSONC. Throws [FormatException] on failure.
  static Object? parseJsonc(String source) => jsonDecode(stripJsonc(source));

  static bool jsonDeepEqual(Object? a, Object? b) => switch ((a, b)) {
    _ when identical(a, b) => true,
    (final Map<Object?, Object?> x, final Map<Object?, Object?> y) =>
      x.length == y.length &&
          x.keys.every((k) => y.containsKey(k) && jsonDeepEqual(x[k], y[k])),
    (final List<Object?> x, final List<Object?> y) =>
      x.length == y.length &&
          x.indexed.every((e) => jsonDeepEqual(e.$2, y[e.$1])),
    _ => a == b,
  };

  static String encodePrettyJson(Object? value) =>
      '${const JsonEncoder.withIndent('  ').convert(value)}\n';

  /// Canonical launch.json fields for the xcross entry (except `args`).
  static Map<String, Object?> xcrossLaunchFields() => {
    'name': xcrossLaunchName,
    'type': 'dart',
    'request': 'launch',
    'debuggerType': 'flutter',
    'program': 'lib/main.dart',
    'xcross': true,
    'cwd': r'${workspaceFolder}',
  };

  /// Overwrite the xcross-managed fields on an existing launch entry while
  /// keeping the user's own keys, their original order, and their `args`
  /// (device flags they typed there must survive a re-run).
  static Map<String, Object?> _withCanonicalFields(
    Map<Object?, Object?> entry,
  ) {
    final merged = <String, Object?>{
      for (final e in entry.entries) '${e.key}': e.value,
    };
    final args = merged.containsKey('args') ? merged['args'] : <Object?>[];
    return merged
      ..addAll(xcrossLaunchFields())
      ..['args'] = args;
  }

  static bool _isXcrossConfig(Object? config) =>
      config is Map &&
      (config['xcross'] == true || config['name'] == xcrossLaunchName);

  /// Upsert the xcross launch configuration into a launch.json document.
  static Map<String, Object?> mergeLaunchDoc(Map<String, Object?>? existing) {
    final doc = <String, Object?>{...?existing};
    doc.putIfAbsent('version', () => '0.2.0');

    final configs = <Object?>[...?doc['configurations'] as List<Object?>?];
    final index = configs.indexWhere(_isXcrossConfig);
    if (index < 0) {
      configs.add({...xcrossLaunchFields(), 'args': <Object?>[]});
    } else {
      configs[index] = _withCanonicalFields(configs[index]! as Map);
    }

    doc['configurations'] = configs;
    return doc;
  }

  /// Upsert xcross DAP settings onto a settings.json document.
  static Map<String, Object?> mergeSettingsDoc(
    Map<String, Object?>? existing,
  ) => {...?existing, dapPathSetting: dapPathValue, promptErrorsSetting: false};
}
