import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/update/update_host_policy.dart';
import 'package:xcross/src/update/internal/file_swap.dart';

final class FixtureRemappedOperations implements FileSwapOperations {
  FixtureRemappedOperations(this.root, {this.failPromotion = false});
  final Directory root;
  final bool failPromotion;
  final moves = <String>[];
  File file(String path) {
    final file = File(
      p.isWithin(root.path, path)
          ? path
          : p.join(root.path, path.replaceFirst(RegExp('^/+'), '')),
    );
    file.parent.createSync(recursive: true);
    return file;
  }

  @override
  Future<bool> exists(String path) => Future.value(file(path).existsSync());
  @override
  Future<void> copy(String source, String target) async {
    await file(source).copy(file(target).path);
  }

  @override
  Future<void> move(String source, String target) async {
    if (failPromotion && source.contains(FileSwap.incomingMarker)) {
      throw FileSystemException('fixture promotion denied', target);
    }
    moves.add('$source -> $target');
    await file(source).rename(file(target).path);
  }

  @override
  Future<void> delete(String path) async {
    await file(path).delete();
  }
}
