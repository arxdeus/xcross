import 'dart:io';

import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_publication_coordinator.dart';

@internal
final class FileSwiftPmPublicationLockProvider
    implements SwiftPmPublicationLockProvider {
  const FileSwiftPmPublicationLockProvider(this.fileSystem);
  final SwiftPmArtifactFileSystem fileSystem;
  @override
  Future<SwiftPmPublicationLock> open(String path) async {
    final file = fileSystem.file(path);
    await file.parent.create(recursive: true);
    return FileSwiftPmPublicationLock(await file.open(mode: FileMode.append));
  }
}

@internal
final class FileSwiftPmPublicationLock implements SwiftPmPublicationLock {
  const FileSwiftPmPublicationLock(this.file);
  final RandomAccessFile file;
  @override
  Future<void> acquire() async {
    await file.lock();
  }

  @override
  Future<void> release() async {
    await file.unlock();
  }

  @override
  Future<void> close() async {
    await file.close();
  }
}
