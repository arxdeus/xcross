// The Linux/bionic ABI shapes the loaded Android library expects, and
// the translation to and from their Windows CRT equivalents. Ported from
// Provision's lib/provision/compat/windows.d plus the vendored
// std_edit/linux_stat.d layout (LGPLv2 — see NOTICE.md).

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

@internal
sealed class LinuxStatLayout {
  const LinuxStatLayout();

  int get size;

  void write(Pointer<Uint8> output, Pointer<Uint8> windowsStat) {
    final bytes = output.asTypedList(size)..fillRange(0, size, 0);
    writeFields(
      ByteData.sublistView(bytes),
      ByteData.sublistView(windowsStat.asTypedList(56)),
    );
  }

  void writeFields(ByteData output, ByteData windowsStat);
}

@internal
final class LinuxX64StatLayout extends LinuxStatLayout {
  const LinuxX64StatLayout();

  @override
  int get size => 144;

  @override
  void writeFields(ByteData output, ByteData windowsStat) {
    final size = windowsStat.getInt64(24, Endian.little);
    output
      ..setUint64(0, windowsStat.getUint32(0, Endian.little), Endian.little)
      ..setUint64(8, windowsStat.getUint16(4, Endian.little), Endian.little)
      ..setUint64(16, windowsStat.getInt16(8, Endian.little), Endian.little)
      ..setUint32(
        24,
        linuxStatMode(windowsStat.getUint16(6, Endian.little)),
        Endian.little,
      )
      ..setUint32(28, windowsStat.getInt16(10, Endian.little), Endian.little)
      ..setUint32(32, windowsStat.getInt16(12, Endian.little), Endian.little)
      ..setUint64(40, windowsStat.getUint32(16, Endian.little), Endian.little)
      ..setInt64(48, size, Endian.little)
      ..setInt64(56, 4096, Endian.little)
      ..setInt64(64, (size + 511) ~/ 512, Endian.little)
      ..setInt64(72, windowsStat.getInt64(32, Endian.little), Endian.little)
      ..setInt64(88, windowsStat.getInt64(40, Endian.little), Endian.little)
      ..setInt64(104, windowsStat.getInt64(48, Endian.little), Endian.little);
  }
}

@internal
final class LinuxArm64StatLayout extends LinuxStatLayout {
  const LinuxArm64StatLayout();

  @override
  int get size => 128;

  @override
  void writeFields(ByteData output, ByteData windowsStat) {
    final size = windowsStat.getInt64(24, Endian.little);
    output
      ..setUint64(0, windowsStat.getUint32(0, Endian.little), Endian.little)
      ..setUint64(8, windowsStat.getUint16(4, Endian.little), Endian.little)
      ..setUint32(
        16,
        linuxStatMode(windowsStat.getUint16(6, Endian.little)),
        Endian.little,
      )
      ..setUint32(20, windowsStat.getInt16(8, Endian.little), Endian.little)
      ..setUint32(24, windowsStat.getInt16(10, Endian.little), Endian.little)
      ..setUint32(28, windowsStat.getInt16(12, Endian.little), Endian.little)
      ..setUint64(32, windowsStat.getUint32(16, Endian.little), Endian.little)
      ..setInt64(48, size, Endian.little)
      ..setInt32(56, 4096, Endian.little)
      ..setInt64(64, (size + 511) ~/ 512, Endian.little)
      ..setInt64(72, windowsStat.getInt64(32, Endian.little), Endian.little)
      ..setInt64(88, windowsStat.getInt64(40, Endian.little), Endian.little)
      ..setInt64(104, windowsStat.getInt64(48, Endian.little), Endian.little);
  }
}

@internal
final class LinuxTimeval extends Struct {
  @Int64()
  external int tvSec;
  @Int64()
  external int tvUsec;
}

@internal
abstract final class WindowsOpenFlags {
  static const int binary = 0x8000;
  static const int creat = 0x0100;
  static const int wronly = 0x0001;
  static const int rdwr = 0x0002;
  static const int rdonly = 0x0000;
  static const int append = 0x0008;
  static const int trunc = 0x0200;
  static const int excl = 0x0400;
  static const int noinherit = 0x0080;

  static int fromLinux(int linuxFlags) {
    var flags = binary;
    if ((linuxFlags & LinuxOpenFlags.creat) != 0) flags |= creat;
    if ((linuxFlags & LinuxOpenFlags.append) != 0) flags |= append;
    if ((linuxFlags & LinuxOpenFlags.trunc) != 0) flags |= trunc;
    if ((linuxFlags & LinuxOpenFlags.excl) != 0) flags |= excl;
    if ((linuxFlags & LinuxOpenFlags.cloexec) != 0) flags |= noinherit;
    return flags | (linuxFlags & 3);
  }

  static int creationMode(int linuxFlags, int linuxMode) =>
      (linuxFlags & LinuxOpenFlags.creat) == 0
      ? 0
      : windowsChmodMode(linuxMode);
}

@internal
abstract final class LinuxOpenFlags {
  static const int creat = 0x40;
  static const int wronly = 0x1;
  static const int rdwr = 0x2;
  static const int excl = 0x80;
  static const int trunc = 0x200;
  static const int append = 0x400;
  static const int cloexec = 0x80000;
}

@internal
int windowsChmodMode(int linuxMode) => (linuxMode & 0x92) != 0 ? 0x180 : 0x100;

@internal
int linuxStatMode(int windowsMode) =>
    (windowsMode & 0xf000) | 0x16d | (windowsMode & 0x80);

@internal
Pointer<Utf8> toWindowsPath(Pointer<Utf8> path) {
  final posix = path.toDartString();
  final stripped = posix.startsWith('//?/') ? posix.substring(4) : posix;
  return stripped.replaceAll('/', r'\').toNativeUtf8();
}
