import 'dart:io';

import 'package:cli_kit/src/shared/platform/platform_host.dart';

extension HostFileSystemInspection on HostFileSystemInterface {
  FileSystemEntityType typeSync(String path, {bool followLinks = true}) {
    if (!followLinks && link(path).existsSync()) {
      return FileSystemEntityType.link;
    }
    return file(path).statSync().type;
  }
}
