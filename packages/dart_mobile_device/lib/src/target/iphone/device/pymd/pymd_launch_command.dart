import 'package:meta/meta.dart';

@internal
abstract final class PymdLaunchCommand {
  static final _specialCharacters = RegExp(r'''[\s'"\\$`]''');

  static String encode(String bundleId, List<String> arguments) =>
      [bundleId, ...arguments].map(_quote).join(' ');

  static String _quote(String value) {
    if (value.isEmpty) return "''";
    if (!_specialCharacters.hasMatch(value)) return value;
    return "'${value.replaceAll("'", r"'\''")}'";
  }
}
