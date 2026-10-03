import 'dart:io';

abstract interface class ConfigHostInterface {
  RegExp get variables;
  String expandHome(String value, String Function(String name) variable);
  bool isExecutable(String path, FileStat stat);
  Future<void> replace(File temporary, File destination);
}
