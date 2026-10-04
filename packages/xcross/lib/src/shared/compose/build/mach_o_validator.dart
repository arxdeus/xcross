import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/errors/errors.dart';

@internal
final class MachOValidator {
  const MachOValidator(this.files);
  final HostFileSystemInterface files;
  static const _littleEndian64Magic = [0xcf, 0xfa, 0xed, 0xfe];
  static const _bigEndian64Magic = [0xfe, 0xed, 0xfa, 0xcf];

  void validate64BitExecutable(String path) {
    final file = files.file(path);
    if (!file.existsSync() || file.lengthSync() < 32) {
      throw XcrossError('Runner Mach-O output is incomplete or missing: $path');
    }
    final handle = file.openSync()..setPositionSync(0);
    try {
      final header = handle.readSync(32);
      final magic = header.take(4).toList(growable: false);
      if (!_matchesMagic(magic, _littleEndian64Magic) &&
          !_matchesMagic(magic, _bigEndian64Magic)) {
        throw XcrossError(
          'Runner output is not a complete 64-bit Mach-O: $path',
        );
      }
    } finally {
      handle.closeSync();
    }
  }

  static bool _matchesMagic(List<int> actual, List<int> expected) {
    for (var i = 0; i < expected.length; i++) {
      if (actual[i] != expected[i]) return false;
    }
    return true;
  }
}
