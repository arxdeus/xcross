import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

final class SwiftPmResponseArguments {
static List<dynamic>? decodeLlbuildArguments(String line) {
const prefix = '    args: ';
if (!line.startsWith('$prefix[')) return null;
try { final decoded=jsonDecode(line.substring(prefix.length));return decoded is List ? decoded : null; } on FormatException { return null; }
}
  static Set<String>? referencedResponseArguments(
    String manifest,
    String scratchPath,
  ) {
    final cache = p.absolute(p.join(scratchPath, '.xcross-response'));
    final arguments = <String>{};
    for (final line in manifest.split('\n')) {
      final decoded = decodeLlbuildArguments(line);
      if (decoded == null) continue;
      for (final reference in decoded.whereType<String>().where((value) => value.startsWith('@')).map((value) => value.substring(1))) {
        final path = p.normalize(p.absolute(reference));
        if (!p.isWithin(cache, path) ||
            FileSystemEntity.isLinkSync(path) ||
            !RegExp(r'^[a-f0-9]{64}\.rsp$').hasMatch(p.basename(path))) {
          continue;
        }
        try {
          arguments.addAll(File(path).readAsLinesSync());
        } on FileSystemException {
          return null;
        }
      }
    }
    return arguments;
  }

  /// Conservative CreateProcess length in UTF-16 units, including the NUL.
  static int windowsCommandLineLength(List<String> arguments) =>
      arguments.map(quoteWindowsArgument).join(' ').length + 1;

  /// Quotes [argument] for `CommandLineToArgvW`, as swiftc parses it.
  static String quoteWindowsArgument(String argument) {
    // Double the backslashes preceding a quote or the closing quote, so they
    // stay literal, and escape each embedded quote.
    final escaped = argument
        .replaceAllMapped(
          RegExp(r'(\\*)"'),
          (match) => '${match[1]}${match[1]}\\"',
        )
        .replaceAllMapped(RegExp(r'\\+$'), (match) => '${match[0]}${match[0]}');
    return '"$escaped"';
  }

  /// Quotes [argument] for a GNU-style response file, as Clang parses it.
  static String quoteGnuArgument(String argument) =>
      '"${argument.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

}
