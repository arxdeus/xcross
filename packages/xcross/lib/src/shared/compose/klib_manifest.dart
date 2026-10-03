import 'dart:convert';

import 'package:archive/archive_io.dart';
import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/errors.dart';

final class KlibManifestReader {
  const KlibManifestReader(this.files);
  final HostFileSystemInterface files;
  Map<String, String> read(String path) {
    String? text;
    if (files.file(path).existsSync()) {
      final input = InputFileStream(files.file(path).path);
      try {
        final archive = ZipDecoder().decodeStream(input);
        for (final entry in archive) {
          if (entry.isFile &&
              (entry.name == 'default/manifest' || entry.name == 'manifest')) {
            text = utf8.decode(entry.readBytes()!);
            break;
          }
        }
      } finally {
        input.closeSync();
      }
    } else {
      for (final candidate in [
        p.join(path, 'default', 'manifest'),
        p.join(path, 'manifest'),
      ]) {
        final file = files.file(candidate);
        if (file.existsSync()) {
          text = file.readAsStringSync();
          break;
        }
      }
    }
    if (text == null) throw XcrossError('No klib manifest in $path.');
    return parseJavaProperties(text);
  }

  /// `java.util.Properties` text format, as far as klib manifests use it:
  /// `key=value` or `key: value` lines, `#`/`!` comments, backslash escapes
  /// (`unique_name=org.jetbrains.kotlinx\:kotlinx-io-core`) and continuation
  /// lines.
}

Map<String, String> parseJavaProperties(String text) {
  final result = <String, String>{};
  final lines = const LineSplitter().convert(text);
  var index = 0;
  while (index < lines.length) {
    var line = lines[index++].trimLeft();
    if (line.isEmpty || line.startsWith('#') || line.startsWith('!')) continue;
    while (_continues(line) && index < lines.length) {
      line = line.substring(0, line.length - 1) + lines[index++].trimLeft();
    }
    final key = StringBuffer();
    var position = 0;
    while (position < line.length) {
      final char = line[position];
      if (char == r'\' && position + 1 < line.length) {
        key.write(_unescape(line[position + 1]));
        position += 2;
        continue;
      }
      if (char == '=' || char == ':' || char == ' ' || char == '\t') break;
      key.write(char);
      position++;
    }
    while (position < line.length && ' \t'.contains(line[position])) {
      position++;
    }
    if (position < line.length && '=:'.contains(line[position])) position++;
    while (position < line.length && ' \t'.contains(line[position])) {
      position++;
    }
    final value = StringBuffer();
    while (position < line.length) {
      final char = line[position];
      if (char == r'\' && position + 1 < line.length) {
        value.write(_unescape(line[position + 1]));
        position += 2;
        continue;
      }
      value.write(char);
      position++;
    }
    result[key.toString()] = value.toString();
  }
  return result;
}

bool _continues(String line) {
  var slashes = 0;
  for (var i = line.length - 1; i >= 0 && line[i] == r'\'; i--) {
    slashes++;
  }
  return slashes.isOdd;
}

String _unescape(String char) => switch (char) {
  't' => '\t',
  'n' => '\n',
  'r' => '\r',
  'f' => '\f',
  _ => char,
};
