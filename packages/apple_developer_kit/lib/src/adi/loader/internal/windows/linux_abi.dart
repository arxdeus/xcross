// The Linux/bionic ABI shapes the loaded Android library expects, and
// the translation to and from their Windows CRT equivalents. Ported from
// Provision's lib/provision/compat/windows.d plus the vendored
// std_edit/linux_stat.d layout (LGPLv2 — see NOTICE.md).
//
// Field names below are the literal C struct member names: the loaded
// library's ABI is defined in terms of them, so they must not be
// camel-cased.
// ignore_for_file: non_constant_identifier_names

part of '../native_symbol_stubs_windows.dart';

/// Linux x86_64 `struct stat`, the layout the loaded library reads back
/// from our `lstat`/`fstat` stubs.
final class LinuxStat extends Struct {
  @Uint64()
  external int st_dev;
  @Uint64()
  external int st_ino;
  @Uint64()
  external int st_nlink;
  @Uint32()
  external int st_mode;
  @Uint32()
  external int st_uid;
  @Uint32()
  external int st_gid;
  @Uint32()
  external int pad0;
  @Uint64()
  external int st_rdev;
  @Int64()
  external int st_size;
  @Int64()
  external int st_blksize;
  @Int64()
  external int st_blocks;
  @Int64()
  external int st_atime;
  @Int64()
  external int st_atimensec;
  @Int64()
  external int st_mtime;
  @Int64()
  external int st_mtimensec;
  @Int64()
  external int st_ctime;
  @Int64()
  external int st_ctimensec;
  @Array(3)
  external Array<Int64> unused;
}

/// Linux `struct timeval`; both members are native words.
final class LinuxTimeval extends Struct {
  @IntPtr()
  external int tv_sec;
  @IntPtr()
  external int tv_usec;
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
    ..st_dev = fields.getUint32(0, Endian.little)
    ..st_ino = fields.getUint16(4, Endian.little)
    ..st_mode = _linuxStatMode(fields.getUint16(6, Endian.little))
    ..st_nlink = fields.getInt16(8, Endian.little)
    ..st_uid = fields.getInt16(10, Endian.little)
    ..st_gid = fields.getInt16(12, Endian.little)
    ..pad0 = 0
    ..st_rdev = fields.getUint32(16, Endian.little)
    ..st_size = fields.getInt64(24, Endian.little)
    ..st_blksize = 4096
    ..st_blocks = (out.ref.st_size + 511) ~/ 512
    ..st_atime = fields.getInt64(32, Endian.little)
    ..st_atimensec = 0
    ..st_mtime = fields.getInt64(40, Endian.little)
    ..st_mtimensec = 0
    ..st_ctime = fields.getInt64(48, Endian.little)
    ..st_ctimensec = 0;
}

/// Rewrites a POSIX path from the loaded library into a Windows one.
///
/// The result is freshly allocated with [malloc]; the caller frees it.
Pointer<Utf8> _toWindowsPath(Pointer<Utf8> path) {
  final posix = path.toDartString();
  final stripped = posix.startsWith('//?/') ? posix.substring(4) : posix;
  return stripped.replaceAll('/', r'\').toNativeUtf8();
}
