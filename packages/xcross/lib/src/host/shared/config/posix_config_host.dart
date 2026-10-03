import 'dart:io';

import 'package:xcross/src/shared/config/config_host.dart';

final class PosixConfigHost implements ConfigHostInterface {
  const PosixConfigHost();

  @override
  RegExp get variables =>
      RegExp(r'\$([A-Za-z_][A-Za-z0-9_]*)|\$\{([A-Za-z_][A-Za-z0-9_]*)\}');

  @override
  String expandHome(String value, String Function(String name) variable) =>
      value == '~' || value.startsWith('~/')
      ? '${variable('HOME')}${value.substring(1)}'
      : value;

  @override
  bool isExecutable(String path, FileStat stat) => stat.mode & 0x49 != 0;

  @override
  Future<void> replace(File temporary, File destination) async {
    await temporary.rename(destination.path);
  }
}
