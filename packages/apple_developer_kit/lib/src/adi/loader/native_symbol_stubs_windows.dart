// Windows stub-symbol table for the manual ELF loader, ported from
// Provision's lib/provision/compat/windows.d + symbols.d (LGPLv2 — see
// NOTICE.md).
//
// Unlike the Linux stubs (which forward open/stat/etc. straight to
// host libc), Windows must translate Linux/bionic open flags and
// struct-stat layouts. Every address published into the ELF GOT is a
// SysV-callable trampoline wrapping an MS-ABI NativeCallable.

// ignore_for_file: non_constant_identifier_names

import 'dart:convert';
import 'dart:ffi';
import 'dart:math';
import 'dart:typed_data';

import 'package:apple_developer_kit/src/adi/elf/elf_loaded_library.dart';
import 'package:apple_developer_kit/src/adi/loader/sysv_abi_bridge.dart';
import 'package:ffi/ffi.dart';

// Linux x86_64 struct stat layout (from Provision std_edit/linux_stat.d).
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

final class LinuxTimeval extends Struct {
  @IntPtr()
  external int tv_sec;
  @IntPtr()
  external int tv_usec;
}

/// Builds the fixed stub-symbol table for Windows, with SysV GOT entries.
class WindowsNativeSymbolStubs {
  WindowsNativeSymbolStubs({required this.loadLibraryForDlopen}) {
    _errnoPtr = calloc<Int32>();
    _bindAll();
  }

  final ElfLoadedLibrary Function(String path) loadLibraryForDlopen;

  final Map<String, Pointer<Void>> _table = {};
  final Map<int, ElfLoadedLibrary> _dlopenHandles = {};
  final List<NativeCallable> _keepAlive = [];
  late final Pointer<Int32> _errnoPtr;

  final DynamicLibrary _ucrt = DynamicLibrary.process();

  Pointer<Void> resolve(String symbolName) => _table[symbolName] ?? nullptr;

  void _publish(String name, Pointer<Void> msAbiFn, int argc) {
    _table[name] = sysvExport(msAbiFn, argc);
  }

  /// Host CRT symbol published as a SysV-callable GOT entry.
  void _publishCrt(String name, int argc, [String? crtName]) {
    _publish(name, _ucrt.lookup<Void>(crtName ?? name).cast(), argc);
  }

  void _bindAll() {
    _publish('open', _callable2(_open), 2);
    _publish('close', _callable1i(_close), 1);
    _publish('read', _callable3(_read), 3);
    _publish('write', _callable3(_write), 3);
    _publish('mkdir', _callable2(_mkdir), 2);
    _publish('chmod', _callable2(_chmod), 2);
    _publish('ftruncate', _callable2i64(_ftruncate), 2);
    _publish('umask', _callable1u(_umask), 1);
    _publish('lstat', _callable2stat(_lstat), 2);
    _publish('fstat', _callable2fstat(_fstat), 2);
    _publish('gettimeofday', _callable2timeval(_gettimeofday), 2);
    _publish('malloc', _callable1malloc(_malloc), 1);
    _publish('free', _callable1free(_free), 1);
    _publish('strncpy', _callable3strncpy(_strncpy), 3);

    _publishCrt('memcpy', 3);
    _publishCrt('memmove', 3);
    _publishCrt('memset', 3);
    _publishCrt('memcmp', 3);
    _publishCrt('memchr', 3);
    _publishCrt('strlen', 1);
    _publishCrt('strcmp', 2);
    _publishCrt('strncmp', 3);
    _publishCrt('strcpy', 2);
    _publishCrt('strcat', 2);
    _publishCrt('strstr', 2);
    _publishCrt('strchr', 2);
    _publishCrt('strrchr', 2);
    _publishCrt('strtol', 3);
    _publishCrt('strtoul', 3);
    _publishCrt('strtoll', 3);
    _publishCrt('strtoull', 3);
    _publishCrt('strtod', 2);
    _publishCrt('atof', 1);
    _publishCrt('atoi', 1);
    _publishCrt('calloc', 2);
    _publishCrt('realloc', 2);
    _publishCrt('abort', 0);
    _publishCrt('strcasecmp', 2, '_stricmp');
    _publishCrt('strncasecmp', 3, '_strnicmp');

    // C++ ABI bits CoreADI references; no-op is enough for our short-lived
    // ADI usage (matches "don't run real destructors" lazy approach).
    final cxaAtexit =
        NativeCallable<
          Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>)
        >.isolateLocal(
          (Pointer<Void> a, Pointer<Void> b, Pointer<Void> c) => 0,
          exceptionalReturn: 0,
        );
    _keepAlive.add(cxaAtexit);
    _publish('__cxa_atexit', cxaAtexit.nativeFunction.cast(), 3);
    final cxaFinalize =
        NativeCallable<Void Function(Pointer<Void>)>.isolateLocal(
          (Pointer<Void> p) {},
        );
    _keepAlive.add(cxaFinalize);
    _publish('__cxa_finalize', cxaFinalize.nativeFunction.cast(), 1);
    _publish('__stack_chk_fail', _ucrt.lookup<Void>('abort').cast(), 0);

    final errnoLoc = NativeCallable<Pointer<Int32> Function()>.isolateLocal(
      () => _errnoPtr,
    );
    _keepAlive.add(errnoLoc);
    _publish('__errno_location', errnoLoc.nativeFunction.cast(), 0);
    _table['__errno'] = _table['__errno_location']!;

    final emptyStub = NativeCallable<Int32 Function()>.isolateLocal(
      () => 0,
      exceptionalReturn: 0,
    );
    _keepAlive.add(emptyStub);
    for (final name in const [
      'pthread_once',
      'pthread_create',
      'pthread_mutex_lock',
      'pthread_mutex_unlock',
      'pthread_rwlock_unlock',
      'pthread_rwlock_destroy',
      'pthread_rwlock_wrlock',
      'pthread_rwlock_init',
      'pthread_rwlock_rdlock',
    ]) {
      _publish(name, emptyStub.nativeFunction.cast(), 0);
    }

    final systemPropertyGet =
        NativeCallable<
          Int32 Function(Pointer<Utf8>, Pointer<Utf8>)
        >.isolateLocal(_systemPropertyGet, exceptionalReturn: -1);
    _keepAlive.add(systemPropertyGet);
    _publish(
      '__system_property_get',
      systemPropertyGet.nativeFunction.cast(),
      2,
    );

    final arc4random = NativeCallable<Uint32 Function()>.isolateLocal(
      () => Random().nextInt(1 << 32),
      exceptionalReturn: 0,
    );
    _keepAlive.add(arc4random);
    _publish('arc4random', arc4random.nativeFunction.cast(), 0);

    final dlopen =
        NativeCallable<Pointer<Void> Function(Pointer<Utf8>)>.isolateLocal(
          _dlopen,
        );
    _keepAlive.add(dlopen);
    _publish('dlopen', dlopen.nativeFunction.cast(), 1);

    final dlsym =
        NativeCallable<
          Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>)
        >.isolateLocal(_dlsym);
    _keepAlive.add(dlsym);
    _publish('dlsym', dlsym.nativeFunction.cast(), 2);

    final dlclose = NativeCallable<Void Function(Pointer<Void>)>.isolateLocal(
      _dlclose,
    );
    _keepAlive.add(dlclose);
    _publish('dlclose', dlclose.nativeFunction.cast(), 1);
  }

  Pointer<Void> _callable1i(int Function(int) fn) {
    final c = NativeCallable<Int32 Function(Int32)>.isolateLocal(
      fn,
      exceptionalReturn: -1,
    );
    _keepAlive.add(c);
    return c.nativeFunction.cast();
  }

  Pointer<Void> _callable1u(int Function(int) fn) {
    final c = NativeCallable<Uint64 Function(Uint64)>.isolateLocal(
      fn,
      exceptionalReturn: 0,
    );
    _keepAlive.add(c);
    return c.nativeFunction.cast();
  }

  Pointer<Void> _callable1malloc(Pointer<Void> Function(int) fn) {
    final c = NativeCallable<Pointer<Void> Function(IntPtr)>.isolateLocal(fn);
    _keepAlive.add(c);
    return c.nativeFunction.cast();
  }

  Pointer<Void> _callable1free(void Function(Pointer<Void>) fn) {
    final c = NativeCallable<Void Function(Pointer<Void>)>.isolateLocal(fn);
    _keepAlive.add(c);
    return c.nativeFunction.cast();
  }

  Pointer<Void> _callable2(int Function(Pointer<Utf8>, int) fn) {
    final c = NativeCallable<Int32 Function(Pointer<Utf8>, Int32)>.isolateLocal(
      fn,
      exceptionalReturn: -1,
    );
    _keepAlive.add(c);
    return c.nativeFunction.cast();
  }

  Pointer<Void> _callable2i64(int Function(int, int) fn) {
    final c = NativeCallable<Int32 Function(Int64, Int64)>.isolateLocal(
      fn,
      exceptionalReturn: -1,
    );
    _keepAlive.add(c);
    return c.nativeFunction.cast();
  }

  Pointer<Void> _callable2stat(
    int Function(Pointer<Utf8>, Pointer<LinuxStat>) fn,
  ) {
    final c =
        NativeCallable<
          Int32 Function(Pointer<Utf8>, Pointer<LinuxStat>)
        >.isolateLocal(fn, exceptionalReturn: -1);
    _keepAlive.add(c);
    return c.nativeFunction.cast();
  }

  Pointer<Void> _callable2fstat(int Function(int, Pointer<LinuxStat>) fn) {
    final c =
        NativeCallable<Int32 Function(Int32, Pointer<LinuxStat>)>.isolateLocal(
          fn,
          exceptionalReturn: -1,
        );
    _keepAlive.add(c);
    return c.nativeFunction.cast();
  }

  Pointer<Void> _callable2timeval(
    int Function(Pointer<LinuxTimeval>, Pointer<Void>) fn,
  ) {
    final c =
        NativeCallable<
          Int32 Function(Pointer<LinuxTimeval>, Pointer<Void>)
        >.isolateLocal(fn, exceptionalReturn: -1);
    _keepAlive.add(c);
    return c.nativeFunction.cast();
  }

  Pointer<Void> _callable3(int Function(int, Pointer<Void>, int) fn) {
    final c =
        NativeCallable<
          Int32 Function(Int32, Pointer<Void>, Uint32)
        >.isolateLocal(fn, exceptionalReturn: -1);
    _keepAlive.add(c);
    return c.nativeFunction.cast();
  }

  Pointer<Void> _callable3strncpy(
    Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, int) fn,
  ) {
    final c =
        NativeCallable<
          Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, IntPtr)
        >.isolateLocal(fn);
    _keepAlive.add(c);
    return c.nativeFunction.cast();
  }

  // --- CRT lookups ---

  late final _openCrt = _ucrt
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Int32),
        int Function(Pointer<Utf8>, int)
      >('_open');
  late final _closeCrt = _ucrt
      .lookupFunction<Int32 Function(Int32), int Function(int)>('_close');
  late final _readCrt = _ucrt
      .lookupFunction<
        Int32 Function(Int32, Pointer<Void>, Uint32),
        int Function(int, Pointer<Void>, int)
      >('_read');
  late final _writeCrt = _ucrt
      .lookupFunction<
        Int32 Function(Int32, Pointer<Void>, Uint32),
        int Function(int, Pointer<Void>, int)
      >('_write');
  late final _mkdirCrt = _ucrt
      .lookupFunction<
        Int32 Function(Pointer<Utf8>),
        int Function(Pointer<Utf8>)
      >('_mkdir');
  late final _chmodCrt = _ucrt
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Int32),
        int Function(Pointer<Utf8>, int)
      >('_chmod');
  late final _chsizeCrt = _ucrt
      .lookupFunction<Int32 Function(Int32, Int64), int Function(int, int)>(
        '_chsize_s',
      );
  late final _statCrt = _ucrt
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Pointer<Uint8>),
        int Function(Pointer<Utf8>, Pointer<Uint8>)
      >('_stat64');
  late final _fstatCrt = _ucrt
      .lookupFunction<
        Int32 Function(Int32, Pointer<Uint8>),
        int Function(int, Pointer<Uint8>)
      >('_fstat64');
  late final _mallocCrt = _ucrt
      .lookupFunction<
        Pointer<Void> Function(IntPtr),
        Pointer<Void> Function(int)
      >('malloc');
  late final _freeCrt = _ucrt
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('free');
  late final _strncpyCrt = _ucrt
      .lookupFunction<
        Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, IntPtr),
        Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, int)
      >('strncpy');

  static const _oBinary = 0x8000;
  static const _oCreat = 0x0100;
  static const _oWronly = 0x0001;
  static const _oRdwr = 0x0002;
  static const _oRdonly = 0x0000;

  // Linux/bionic flag bits (octal in upstream windows.d).
  static const _linuxOCreat = 0x40; // 0100
  static const _linuxOWronly = 0x1;
  static const _linuxORdwr = 0x2;

  Pointer<Utf8> _toWindowsPath(Pointer<Utf8> path) {
    var s = path.toDartString();
    if (s.startsWith('//?/')) s = s.substring(4);
    s = s.replaceAll('/', r'\');
    return s.toNativeUtf8();
  }

  int _open(Pointer<Utf8> path, int oflag) {
    var converted = _oBinary;
    if ((oflag & _linuxOCreat) != 0) converted |= _oCreat;
    if ((oflag & _linuxOWronly) != 0) {
      converted |= _oWronly;
    } else if ((oflag & _linuxORdwr) != 0) {
      converted |= _oRdwr;
    } else {
      converted |= _oRdonly;
    }
    final winPath = _toWindowsPath(path);
    try {
      final result = _openCrt(winPath, converted);
      if (result < 0) _errnoPtr.value = 2; // ENOENT-ish
      return result;
    } finally {
      malloc.free(winPath);
    }
  }

  int _close(int fd) => _closeCrt(fd);

  int _read(int fd, Pointer<Void> buf, int count) => _readCrt(fd, buf, count);

  int _write(int fd, Pointer<Void> buf, int count) => _writeCrt(fd, buf, count);

  int _mkdir(Pointer<Utf8> path, int mode) {
    final winPath = _toWindowsPath(path);
    try {
      return _mkdirCrt(winPath);
    } finally {
      malloc.free(winPath);
    }
  }

  int _chmod(Pointer<Utf8> path, int mode) {
    final winPath = _toWindowsPath(path);
    try {
      // Map a crude write bit into Windows _S_IWRITE (0x80).
      final winMode = (mode & 0x80) != 0 || (mode & 0x02) != 0
          ? 0x80 | 0x100
          : 0x100;
      return _chmodCrt(winPath, winMode);
    } finally {
      malloc.free(winPath);
    }
  }

  int _ftruncate(int fd, int length) => _chsizeCrt(fd, length);

  int _umask(int mask) => mask; // upstream returns the argument unchanged

  // MSVC _stat64 is 48 bytes on x64: dev(4)+ino(2)+mode(2)+nlink(2)+uid(2)+gid(2)+rdev(4)+pad + size(8)+atime(8)+mtime(8)+ctime(8)
  // Actually _stat64 structure varies. Use a generous buffer and read known offsets for _stat64:
  // On VS: struct __stat64 { _dev_t st_dev; _ino_t st_ino; unsigned short st_mode; short st_nlink; short st_uid; short st_gid; _dev_t st_rdev; __int64 st_size; __time64_t st_atime, st_mtime, st_ctime; }
  // Layout roughly: 0:dev(4), 4:ino(2), 6:mode(2), 8:nlink(2), 10:uid(2), 12:gid(2), 16:rdev(4), 24:size(8), 32:atime(8), 40:mtime(8), 48:ctime(8) = 56

  void _fillLinuxStat(Pointer<LinuxStat> out, Pointer<Uint8> winStat) {
    final b = winStat.asTypedList(56);
    final bd = ByteData.sublistView(b);
    out.ref
      ..st_dev = bd.getUint32(0, Endian.little)
      ..st_ino = bd.getUint16(4, Endian.little)
      ..st_mode = _linuxMode(bd.getUint16(6, Endian.little))
      ..st_nlink = bd.getInt16(8, Endian.little)
      ..st_uid = bd.getInt16(10, Endian.little)
      ..st_gid = bd.getInt16(12, Endian.little)
      ..pad0 = 0
      ..st_rdev = bd.getUint32(16, Endian.little)
      ..st_size = bd.getInt64(24, Endian.little)
      ..st_blksize = 4096
      ..st_blocks = (out.ref.st_size + 511) ~/ 512
      ..st_atime = bd.getInt64(32, Endian.little)
      ..st_atimensec = 0
      ..st_mtime = bd.getInt64(40, Endian.little)
      ..st_mtimensec = 0
      ..st_ctime = bd.getInt64(48, Endian.little)
      ..st_ctimensec = 0;
  }

  // Ported from windows.d mode translation (simplified).
  static int _linuxMode(int winMode) {
    var mode = 0x1ed; // 0555
    if ((winMode & 0x0080) != 0) mode |= 0x80; // write
    if ((winMode & 0x4000) != 0) mode |= 0x4000; // dir
    return mode;
  }

  int _lstat(Pointer<Utf8> path, Pointer<LinuxStat> out) {
    final winPath = _toWindowsPath(path);
    final buf = calloc<Uint8>(64);
    try {
      final rc = _statCrt(winPath, buf);
      if (rc != 0) {
        _errnoPtr.value = 2;
        return rc;
      }
      _fillLinuxStat(out, buf);
      return 0;
    } finally {
      calloc.free(buf);
      malloc.free(winPath);
    }
  }

  int _fstat(int fd, Pointer<LinuxStat> out) {
    final buf = calloc<Uint8>(64);
    try {
      final rc = _fstatCrt(fd, buf);
      if (rc != 0) {
        _errnoPtr.value = 9;
        return rc;
      }
      _fillLinuxStat(out, buf);
      return 0;
    } finally {
      calloc.free(buf);
    }
  }

  int _gettimeofday(Pointer<LinuxTimeval> tv, Pointer<Void> tz) {
    final now = DateTime.now().toUtc();
    tv.ref
      ..tv_sec = now.millisecondsSinceEpoch ~/ 1000
      ..tv_usec = (now.millisecondsSinceEpoch % 1000) * 1000;
    return 0;
  }

  Pointer<Void> _malloc(int size) => _mallocCrt(size);

  void _free(Pointer<Void> ptr) => _freeCrt(ptr);

  Pointer<Utf8> _strncpy(Pointer<Utf8> dest, Pointer<Utf8> src, int n) =>
      _strncpyCrt(dest, src, n);

  static int _systemPropertyGet(Pointer<Utf8> _, Pointer<Utf8> value) {
    const placeholder = 'no s/n number';
    final bytes = ascii.encode(placeholder);
    value.cast<Uint8>().asTypedList(bytes.length).setAll(0, bytes);
    return bytes.length;
  }

  Pointer<Void> _dlopen(Pointer<Utf8> namePtr) {
    final path = namePtr.toDartString();
    try {
      final lib = loadLibraryForDlopen(path);
      // Opaque heap handle — never return the ELF mapping address. ADI may
      // treat the dlopen result like a malloc'd object in edge paths; giving
      // it VirtualAlloc base has been a crash suspect after dlsym.
      final handle = malloc<IntPtr>();
      handle.value = lib.base.address;
      _dlopenHandles[handle.address] = lib;
      return handle.cast();
    } catch (_) {
      return nullptr;
    }
  }

  Pointer<Void> _dlsym(Pointer<Void> handle, Pointer<Utf8> symbolNamePtr) {
    final lib = _dlopenHandles[handle.address];
    if (lib == null) return nullptr;
    try {
      return lib.lookup(symbolNamePtr.toDartString());
    } catch (_) {
      return nullptr;
    }
  }

  void _dlclose(Pointer<Void> handle) {
    _dlopenHandles.remove(handle.address);
    malloc.free(handle.cast<IntPtr>());
  }
}
