import 'dart:convert';

/// JSONC parse/merge helpers for VS Code launch.json / settings.json.
abstract final class VscodeJsonMerge {
  /// Strip JSONC sugar VS Code allows: `//` / `/* */` comments and trailing
  /// commas before `}` / `]`. Strings are left untouched.
  static String stripJsonc(String source) {
    final out = StringBuffer();
    var i = 0;
    var inString = false;
    while (i < source.length) {
      final c = source[i];
      if (inString) {
        out.write(c);
        if (c == r'\' && i + 1 < source.length) {
          out.write(source[i + 1]);
          i += 2;
          continue;
        }
        if (c == '"') inString = false;
        i++;
        continue;
      }
      if (c == '"') {
        inString = true;
        out.write(c);
        i++;
        continue;
      }
      if (c == '/' && i + 1 < source.length) {
        final next = source[i + 1];
        if (next == '/') {
          i += 2;
          while (i < source.length && source[i] != '\n') {
            i++;
          }
          continue;
        }
        if (next == '*') {
          i += 2;
          while (i + 1 < source.length &&
              !(source[i] == '*' && source[i + 1] == '/')) {
            i++;
          }
          i = i + 2 <= source.length ? i + 2 : source.length;
          continue;
        }
      }
      // Trailing comma: `,` then optional whitespace/comments then `}` or `]`.
      if (c == ',') {
        final after = _skipJsoncTrivia(source, i + 1);
        if (after < source.length &&
            (source[after] == '}' || source[after] == ']')) {
          i = after;
          continue;
        }
      }
      out.write(c);
      i++;
    }
    return out.toString();
  }

  static bool _isJsoncSpace(String c) =>
      c == ' ' || c == '\t' || c == '\n' || c == '\r';

  /// Skip whitespace and comments; returns the index of the next real token.
  static int _skipJsoncTrivia(String source, int start) {
    var j = start;
    while (j < source.length) {
      while (j < source.length && _isJsoncSpace(source[j])) {
        j++;
      }
      if (j + 1 < source.length && source[j] == '/' && source[j + 1] == '/') {
        j += 2;
        while (j < source.length && source[j] != '\n') {
          j++;
        }
        continue;
      }
      if (j + 1 < source.length && source[j] == '/' && source[j + 1] == '*') {
        j += 2;
        while (j + 1 < source.length &&
            !(source[j] == '*' && source[j + 1] == '/')) {
          j++;
        }
        j = j + 2 <= source.length ? j + 2 : source.length;
        continue;
      }
      break;
    }
    return j;
  }

  /// Parse JSON or JSONC. Throws [FormatException] on failure.
  static Object? parseJsonc(String source) => jsonDecode(stripJsonc(source));

  static bool jsonDeepEqual(Object? a, Object? b) {
    if (identical(a, b)) return true;
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final key in a.keys) {
        if (!b.containsKey(key) || !jsonDeepEqual(a[key], b[key])) {
          return false;
        }
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!jsonDeepEqual(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }

  static String encodePrettyJson(Object? value) =>
      '${const JsonEncoder.withIndent('  ').convert(value)}\n';

  /// Canonical launch.json fields for the xcross entry (except [args]).
  static Map<String, Object?> xcrossLaunchFields() => {
    'name': xcrossLaunchName,
    'type': 'dart',
    'request': 'launch',
    'debuggerType': 'flutter',
    'program': 'lib/main.dart',
    'xcross': true,
    'cwd': r'${workspaceFolder}',
  };

  /// Upsert the xcross launch configuration into a launch.json document.
  static Map<String, Object?> mergeLaunchDoc(Map<String, Object?>? existing) {
    final doc = <String, Object?>{if (existing != null) ...existing};
    doc.putIfAbsent('version', () => '0.2.0');

    final configs = <Object?>[
      ...?((doc['configurations'] as List?)?.map((e) => e)),
    ];

    final canonical = xcrossLaunchFields();
    final idx = configs.indexWhere((c) {
      if (c is! Map) return false;
      return c['xcross'] == true || c['name'] == xcrossLaunchName;
    });

    if (idx < 0) {
      configs.add({...canonical, 'args': <Object?>[]});
    } else {
      final matched = configs[idx]! as Map;
      final old = <String, Object?>{
        for (final e in matched.entries) '${e.key}': e.value,
      };
      final preservedArgs = old.containsKey('args') ? old['args'] : <Object?>[];
      old.addAll(canonical);
      old['args'] = preservedArgs;
      configs[idx] = old;
    }

    doc['configurations'] = configs;
    return doc;
  }

  /// Upsert xcross DAP settings onto a settings.json document.
  static Map<String, Object?> mergeSettingsDoc(Map<String, Object?>? existing) {
    return <String, Object?>{
      if (existing != null) ...existing,
      dapPathSetting: dapPathValue,
      promptErrorsSetting: false,
    };
  }
}

const String xcrossLaunchName = 'xcross: iOS device';
const String dapPathSetting = 'dart.customFlutterDapPath';
const String dapPathValue = '.vscode/xcross_dap.dart';
const String promptErrorsSetting = 'dart.promptToRunIfErrors';
