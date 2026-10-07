import 'dart:io';
import 'package:meta/meta.dart';

@internal
abstract interface class SetupScriptPolicy {
  /// Script `xcross setup` runs when the config names none, or null to use
  /// the built-in requirement installer.
  String? get defaultSource;
  File cachedFile(String digest);
  File cachePointer(String digest);
  Future<({String executable, List<String> arguments})> invocation(String path);
  void replace(File temporary, File destination);
}
