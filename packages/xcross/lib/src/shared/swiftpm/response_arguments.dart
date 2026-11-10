import 'dart:convert';
import 'package:meta/meta.dart';

@internal
final class SwiftPmResponseArguments {
  static List<dynamic>? decodeLlbuildArguments(String line) {
    const prefix = '    args: ';
    if (!line.startsWith('$prefix[')) return null;
    try {
      final decoded = jsonDecode(line.substring(prefix.length));
      return decoded is List ? decoded : null;
    } on FormatException {
      return null;
    }
  }

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
