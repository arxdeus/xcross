import 'package:meta/meta.dart';
import 'package:xcross/src/shared/update/install_layout.dart';

@internal
abstract interface class UpdateHostPolicy {
  String releaseAsset();
  Future<FileSwapOperations> prepare(InstallLayout layout);
}

@internal
abstract interface class FileSwapOperations {
  Future<bool> exists(String path);
  Future<void> copy(String source, String target);
  Future<void> move(String source, String target);
  Future<void> delete(String path);
}
