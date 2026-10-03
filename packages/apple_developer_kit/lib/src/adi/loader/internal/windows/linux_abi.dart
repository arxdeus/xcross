// The Linux/bionic ABI shapes the loaded Android library expects, and
// the translation to and from their Windows CRT equivalents. Ported from
// Provision's lib/provision/compat/windows.d plus the vendored
// std_edit/linux_stat.d layout (LGPLv2 — see NOTICE.md).

part of '../native_symbol_stubs_windows.dart';

/// Linux x86_64 `struct stat`, the layout the loaded library reads back
/// from our `lstat`/`fstat` stubs.
final class LinuxStat extends Struct {
  @Uint64()
  external int stDev;
  @Uint64()
  external int stIno;
  @Uint64()
  external int stNlink;
  @Uint32()
  external int stMode;
  @Uint32()
  external int stUid;
  @Uint32()
  external int stGid;
  @Uint32()
  external int pad0;
  @Uint64()
  external int stRdev;
  @Int64()
  external int stSize;
  @Int64()
  external int stBlksize;
  @Int64()
  external int stBlocks;
  @Int64()
  external int stAtime;
  @Int64()
  external int stAtimensec;
  @Int64()
  external int stMtime;
  @Int64()
  external int stMtimensec;
  @Int64()
  external int stCtime;
  @Int64()
  external int stCtimensec;
  @Array(3)
  external Array<Int64> unused;
}

/// Linux `struct timeval`; both members are native words.
final class LinuxTimeval extends Struct {
  @IntPtr()
  external int tvSec;
  @IntPtr()
  external int tvUsec;
}

/// Windows CRT `_O_*` flags (`fcntl.h`).
abstract final class WindowsOpenFlags {
  static const int binary = 0x8000;
  static const int creat = 0x0100;
  static const int wronly = 0x0001;
  static const int rdwr = 0x0002;
  static const int rdonly = 0x0000;
}

/// Linux/bionic `O_*` flags, whose bit values differ from the Windows
/// CRT's (upstream windows.d spells these in octal).
abstract final class LinuxOpenFlags {
  /// `O_CREAT`, octal 0100.
  static const int creat = 0x40;
  static const int wronly = 0x1;
  static const int rdwr = 0x2;
}

/// Translates bionic `open()` flags into Windows CRT `_open()` flags.
///
/// Always binary: the CRT would otherwise perform CRLF translation on the
/// provisioning blobs ADI reads and writes.
int _windowsOpenFlags(int linuxFlags) {
  var flags = WindowsOpenFlags.binary;
  if ((linuxFlags & LinuxOpenFlags.creat) != 0) {
    flags |= WindowsOpenFlags.creat;
  }
  if ((linuxFlags & LinuxOpenFlags.wronly) != 0) {
    flags |= WindowsOpenFlags.wronly;
  } else if ((linuxFlags & LinuxOpenFlags.rdwr) != 0) {
    flags |= WindowsOpenFlags.rdwr;
  } else {
    flags |= WindowsOpenFlags.rdonly;
  }
  return flags;
}

/// Linux `st_mode` permission bits this crude translation looks at.
const int _linuxWriteUser = 0x80; // S_IWUSR, octal 0200
const int _linuxWriteOther = 0x02; // S_IWOTH, octal 0002
const int _linuxReadExecuteAll = 0x1ed; // octal 0555
const int _statIfdir = 0x4000; // S_IFDIR / _S_IFDIR

/// Windows CRT `_chmod` permission bits (`sys/stat.h`).
const int _windowsWrite = 0x80; // _S_IWRITE
const int _windowsRead = 0x100; // _S_IREAD

/// Windows `_chmod` models only a single user-write bit, so any Linux
/// write permission collapses onto it.
int _windowsChmodMode(int linuxMode) =>
    (linuxMode & _linuxWriteUser) != 0 || (linuxMode & _linuxWriteOther) != 0
    ? _windowsWrite | _windowsRead
    : _windowsRead;

/// Windows `_stat64` `st_mode` -> Linux `st_mode`. Ported (simplified)
/// from windows.d's mode translation: everything is reported
/// readable/executable, plus the user-write and directory bits when
/// Windows reports them.
int _linuxStatMode(int windowsMode) {
  var mode = _linuxReadExecuteAll;
  if ((windowsMode & _windowsWrite) != 0) mode |= _linuxWriteUser;
  if ((windowsMode & _statIfdir) != 0) mode |= _statIfdir;
  return mode;
}

/// Bytes of MSVC's `struct __stat64` that carry the fields we translate.
/// The rest of the 64-byte scratch buffer is padding.
const int _windowsStatSize = 56;

/// Translates an MSVC `struct __stat64` (as written by `_stat64` /
/// `_fstat64` into a raw scratch buffer) into [LinuxStat].
///
/// x64 `__stat64` field offsets:
///
///     0  st_dev   (4)     16 st_rdev (4)     32 st_atime (8)
///     4  st_ino   (2)     24 st_size (8)     40 st_mtime (8)
///     6  st_mode  (2)                        48 st_ctime (8)
///     8  st_nlink (2)
///     10 st_uid   (2)
///     12 st_gid   (2)
void _fillLinuxStat(Pointer<LinuxStat> out, Pointer<Uint8> windowsStat) {
  final fields = ByteData.sublistView(
    windowsStat.asTypedList(_windowsStatSize),
  );
  out.ref
    ..stDev = fields.getUint32(0, Endian.little)
    ..stIno = fields.getUint16(4, Endian.little)
    ..stMode = _linuxStatMode(fields.getUint16(6, Endian.little))
    ..stNlink = fields.getInt16(8, Endian.little)
    ..stUid = fields.getInt16(10, Endian.little)
    ..stGid = fields.getInt16(12, Endian.little)
    ..pad0 = 0
    ..stRdev = fields.getUint32(16, Endian.little)
    ..stSize = fields.getInt64(24, Endian.little)
    ..stBlksize = 4096
    ..stBlocks = (out.ref.stSize + 511) ~/ 512
    ..stAtime = fields.getInt64(32, Endian.little)
    ..stAtimensec = 0
    ..stMtime = fields.getInt64(40, Endian.little)
    ..stMtimensec = 0
    ..stCtime = fields.getInt64(48, Endian.little)
    ..stCtimensec = 0;
}

/// Rewrites a POSIX path from the loaded library into a Windows one.
///
/// The result is freshly allocated with [malloc]; the caller frees it.
Pointer<Utf8> _toWindowsPath(Pointer<Utf8> path) {
  final posix = path.toDartString();
  final stripped = posix.startsWith('//?/') ? posix.substring(4) : posix;
  return stripped.replaceAll('/', r'\').toNativeUtf8();
}
