import 'package:archive/archive.dart';
import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/update/internal/archive_entry_path.dart';

/// The `bin/` + `lib/` payload unpacked from a release archive.
///
/// A downloaded archive is untrusted input, so every entry is validated before
/// it becomes a path and anything outside the two payload directories is
/// ignored rather than written.
final class ReleasePayload {
  const ReleasePayload(this.host);

  final PlatformHostInterface host;

  /// Directories an update replaces. The Windows zip also ships `LICENSE` and
  /// `THIRD_PARTY_LICENSES/`, which the installers place but updates leave
  /// alone.
  static const payloadDirs = {'bin', 'lib'};

  /// Unpacks [bytes] into [destination] and checks the result is a usable
  /// bundle.
  ///
  /// [asset] selects the container format and names the archive in errors.
  /// [executableName] is the binary the bundle must contain.
  Future<void> extract({
    required List<int> bytes,
    required String asset,
    required String destination,
    required String executableName,
  }) async {
    final archive = asset.endsWith('.zip')
        ? ZipDecoder().decodeBytes(bytes)
        : TarDecoder().decodeBytes(const GZipDecoder().decodeBytes(bytes));

    final paths = host.paths.context;
    await host.fileSystem.directory(destination).create(recursive: true);
    for (final entry in archive) {
      // `isFile` stays true for a tar symlink entry, whose payload is a target
      // path rather than content; writing it would produce a plausible-looking
      // but empty binary.
      if (entry.isSymbolicLink) {
        throw XcrossError(
          'refusing to extract $asset: link entry "${entry.name}"',
        );
      }
      if (!entry.isFile) continue;
      final relative = ArchiveEntryPath.sanitize(entry.name);
      final target = relative == null
          ? null
          : paths.joinAll([destination, ...relative.split('/')]);
      if (target == null) {
        throw XcrossError(
          'refusing to extract $asset: unsafe entry "${entry.name}"',
        );
      }
      final segments = relative!.split('/');
      if (segments.length < 2 || !payloadDirs.contains(segments.first)) {
        continue;
      }
      await host.fileSystem
          .directory(paths.dirname(target))
          .create(recursive: true);
      await host.fileSystem.file(target).writeAsBytes(entry.content);
    }

    _assertComplete(
      destination: destination,
      asset: asset,
      executableName: executableName,
    );
  }

  /// A half-populated payload must be caught here, before anything installed
  /// is touched.
  void _assertComplete({
    required String destination,
    required String asset,
    required String executableName,
  }) {
    final binary = host.fileSystem.file(
      host.paths.context.join(destination, 'bin', executableName),
    );
    if (!binary.existsSync() || binary.lengthSync() == 0) {
      throw XcrossError('$asset is missing bin/$executableName');
    }
    final libDir = host.fileSystem.directory(
      host.paths.context.join(destination, 'lib'),
    );
    if (!libDir.existsSync() || libDir.listSync().isEmpty) {
      throw XcrossError('$asset is missing its lib/ payload');
    }
  }
}
