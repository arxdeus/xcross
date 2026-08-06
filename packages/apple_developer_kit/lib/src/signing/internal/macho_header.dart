import 'dart:typed_data';

import 'package:apple_developer_kit/src/signing/macho_format.dart';

/// `mach_header_64` after magic, CPU, and command-table validation.
final class MachOHeader {
  const MachOHeader({
    required this.fileType,
    required this.ncmds,
    required this.sizeofcmds,
    required this.commandsEnd,
  });

  factory MachOHeader.read(Uint8List bytes, String path) {
    if (bytes.length < 4) machoFail(path, 'magic', 'file is truncated');
    _requireThinArm64Magic(readU32le(bytes, MachHeader64.magic), path);
    requireRange(bytes, 0, MachHeader64.size, path, 'mach_header_64');
    if (readU32le(bytes, MachHeader64.cpuType) != cpuTypeArm64) {
      machoFail(path, 'mach_header_64.cputype', 'only ARM64 is supported');
    }
    final ncmds = readU32le(bytes, MachHeader64.ncmds);
    final sizeofcmds = readU32le(bytes, MachHeader64.sizeofcmds);
    final commandsEnd = checkedAdd(
      MachHeader64.size,
      sizeofcmds,
      bytes.length,
      path,
      'mach_header_64.sizeofcmds',
    );
    // Every load command is at least LoadCommand.size bytes, so more commands
    // than that many slots cannot possibly fit.
    if (ncmds > sizeofcmds ~/ LoadCommand.size) {
      machoFail(path, 'mach_header_64.ncmds', 'cannot fit in sizeofcmds');
    }
    return MachOHeader(
      fileType: readU32le(bytes, MachHeader64.fileType),
      ncmds: ncmds,
      sizeofcmds: sizeofcmds,
      commandsEnd: commandsEnd,
    );
  }

  static void _requireThinArm64Magic(int magic, String path) {
    if (magic == fatMagic || magic == fatCigam) {
      machoFail(path, 'magic', 'FAT Mach-O files are unsupported');
    }
    if (magic == mhMagic || magic == mhCigam) {
      machoFail(path, 'magic', '32-bit Mach-O files are unsupported');
    }
    if (magic == mhCigam64) {
      machoFail(path, 'magic', 'big-endian Mach-O files are unsupported');
    }
    if (magic != mhMagic64) {
      machoFail(path, 'magic', 'not a 64-bit little-endian Mach-O');
    }
  }

  final int fileType;
  final int ncmds;
  final int sizeofcmds;
  final int commandsEnd;
}
