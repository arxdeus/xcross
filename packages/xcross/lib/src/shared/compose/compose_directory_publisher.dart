import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/compose/compose_install_effects.dart';
import 'package:xcross/src/shared/errors/errors.dart';

final class ComposeDirectoryPublisher {
  const ComposeDirectoryPublisher({
    required this.files,
    required this.renameDirectory,
  });
  final HostFileSystemInterface files;
  final RenameDirectory renameDirectory;
  Future<void> publish(
    Directory staging,
    Directory destination, {
    required bool force,
  }) async {
    await destination.parent.create(recursive: true);
    Directory? backupContainer;
    String? backupPath;
    if (destination.existsSync()) {
      if (!force) {
        throw XcrossError(
          '${destination.path} already exists. Use force to reinstall.',
        );
      }
      backupContainer = await destination.parent.createTemp('.compose-backup-');
      backupPath = p.join(backupContainer.path, 'toolchain');
      await renameDirectory(destination, backupPath);
    }
    try {
      await renameDirectory(staging, destination.path);
    } on FileSystemException catch (error) {
      await _restoreBackupOrThrow(destination, backupPath, error);
      await _deleteBackupContainer(backupContainer);
      throw XcrossError(
        'Failed to replace Compose Kotlin/Native cache at ${destination.path}: $error',
      );
    } catch (error) {
      await _restoreBackupOrThrow(destination, backupPath, error);
      await _deleteBackupContainer(backupContainer);
      rethrow;
    }
    await _deleteBackupContainer(backupContainer);
  }

  Future<void> _restoreBackupOrThrow(
    Directory destination,
    String? backupPath,
    Object installError,
  ) async {
    if (backupPath == null) return;
    try {
      if (destination.existsSync()) await destination.delete(recursive: true);
      if (files.directory(backupPath).existsSync()) {
        await renameDirectory(files.directory(backupPath), destination.path);
      }
    } catch (restoreError) {
      throw XcrossError(
        'Failed to replace Compose Kotlin/Native cache at ${destination.path} and failed to restore the previous cache. '
        'Previous cache backup preserved at $backupPath. '
        'Install error: $installError. Restore error: $restoreError',
      );
    }
  }

  Future<void> _deleteBackupContainer(Directory? backupContainer) async {
    if (backupContainer != null && backupContainer.existsSync()) {
      await backupContainer.delete(recursive: true);
    }
  }
}
