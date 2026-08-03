import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xcross_flutter/src/errors.dart';

/// Merging of dart-define sources into `KEY=VALUE` strings.
abstract final class DartDefines {
  /// Merge dart-define sources into ordered `KEY=VALUE` strings. File entries
  /// are emitted first; explicit `--dart-define` entries are appended last so
  /// they win when frontend_server resolves duplicate keys (last-wins). ORDER
  /// MATTERS: de-duplicating or sorting this list inverts which value the app
  /// sees.
  static Future<List<String>> mergeDartDefines(
    List<String> fromFiles,
    List<String> explicit,
  ) async {
    final result = <String>[];
    for (final path in fromFiles) {
      result.addAll(await _readDefineFile(path));
    }
    result.addAll(explicit);
    return result;
  }

  /// Parse a `--dart-define-from-file` source (`.json` object or `.env`-style
  /// `KEY=VALUE` lines) into `KEY=VALUE` strings.
  static Future<List<String>> _readDefineFile(String path) async {
    final file = File(path);
    if (!file.existsSync()) {
      throw FlutterBuildError('--dart-define-from-file: file not found: $path');
    }
    final content = await file.readAsString();
    final trimmed = content.trimLeft();
    if (p.extension(path) == '.json' || trimmed.startsWith('{')) {
      final decoded = jsonDecode(content);
      if (decoded is! Map) {
        throw FlutterBuildError(
          '--dart-define-from-file: $path is not a JSON object',
        );
      }
      // Dart's default toString keeps JSON true/1/1.5 as bare tokens;
      // jsonEncode here would quote strings and change every emitted define.
      return decoded.entries.map((e) => '${e.key}=${e.value}').toList();
    }
    // .env style: KEY=VALUE lines, ignore blanks and # comments. The whole
    // line is kept verbatim (never re-joined around '=') so values containing
    // '=' — base64, URLs, JWTs — survive byte-exact.
    final defines = <String>[];
    for (final raw in const LineSplitter().convert(content)) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      if (!line.contains('=')) continue;
      defines.add(line);
    }
    return defines;
  }
}
