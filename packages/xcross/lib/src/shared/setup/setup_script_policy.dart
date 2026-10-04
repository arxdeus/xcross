import 'dart:io';
import 'package:meta/meta.dart';

@internal
abstract interface class SetupScriptPolicy {
  File cachedFile(String digest);
  File cachePointer(String digest);
  Future<({String executable, List<String> arguments})> invocation(String path);
  void replace(File temporary, File destination);
}
