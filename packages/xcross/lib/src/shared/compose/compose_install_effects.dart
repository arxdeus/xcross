import 'dart:io';
import 'package:xcross/src/shared/compose/compose_setup_options.dart';

typedef DownloadToFile = Future<void> Function(String url, File file);
typedef DigestFile = Future<String> Function(File file);
typedef ExtractArchive =
    Future<void> Function(File archive, Directory destination);
typedef PatchCompilerJar = Future<void> Function(File jar);
typedef RunChecked =
    Future<void> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    });
typedef InstallRoot =
    Future<String> Function(ComposeSetupOptions options, {required bool force});
typedef RenameDirectory =
    Future<Directory> Function(Directory source, String newPath);
