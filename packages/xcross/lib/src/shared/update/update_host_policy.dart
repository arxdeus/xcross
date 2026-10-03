import 'package:xcross/src/update/install_layout.dart';

abstract interface class UpdateHostPolicy {
  String releaseAsset();
  Future<FileSwapOperations> prepare(InstallLayout layout);
}

abstract interface class FileSwapOperations {
  Future<bool> exists(String path);
  Future<void> copy(String source, String target);
  Future<void> move(String source, String target);
  Future<void> delete(String path);
}
