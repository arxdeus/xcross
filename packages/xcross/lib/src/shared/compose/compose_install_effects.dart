import 'dart:io';

import 'package:meta/meta.dart';
import 'package:xcross/src/shared/compose/compose_setup_options.dart';

@internal
typedef DownloadToFile = Future<void> Function(String url, File file);
@internal
typedef DigestFile = Future<String> Function(File file);
@internal
typedef ExtractArchive =
    Future<void> Function(File archive, Directory destination);
@internal
typedef PatchCompilerJar = Future<void> Function(File jar);
@internal
typedef RunChecked =
    Future<void> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    });
@internal
typedef InstallRoot =
    Future<String> Function(ComposeSetupOptions options, {required bool force});
@internal
typedef RenameDirectory =
    Future<Directory> Function(Directory source, String newPath);
