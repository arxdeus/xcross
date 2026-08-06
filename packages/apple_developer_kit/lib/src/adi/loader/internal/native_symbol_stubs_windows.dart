// Windows stub-symbol table for the manual ELF loader, ported from
// Provision's lib/provision/compat/windows.d + symbols.d (LGPLv2 — see
// NOTICE.md).
//
// Unlike the Linux stubs (which forward open/stat/etc. straight to host
// libc), Windows must translate Linux/bionic open flags and struct-stat
// layouts — see windows/linux_abi.dart. Every address published into the
// ELF GOT is a SysV-callable trampoline wrapping an MS-ABI
// NativeCallable, because the loaded library calls its imports with the
// SysV AMD64 convention while Dart's NativeCallable speaks the Microsoft
// x64 one (different argument registers, different shadow space, no red
// zone).
//
// DO NOT "IMPROVE" THE PTHREAD STUBS: they are deliberately no-ops,
// matching upstream's `emptyStub` in symbols.d. Bionic's
// `pthread_mutex_t`/`pthread_once_t` are ~4 bytes; glibc's and the CRT's
// equivalents are far larger. A real implementation running against a
// bionic-sized field inside the loaded library's own memory would
// silently write past it. That is precisely why this custom loader
// exists instead of a plain `dlopen()` — see NOTICE.md.

import 'dart:convert';
import 'dart:ffi';
import 'dart:math';
import 'dart:typed_data';

import 'package:apple_developer_kit/src/adi/elf/elf_loaded_library.dart';
import 'package:apple_developer_kit/src/adi/loader/internal/sysv_abi_bridge.dart';
import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

part 'windows/linux_abi.dart';
part 'windows/windows_crt.dart';

/// Builds the fixed stub-symbol table for Windows, with SysV GOT entries.
///
/// The set of symbol name strings, and the exact value each stub returns,
/// are load-bearing: a missing entry becomes a null GOT slot the loaded
/// library will call straight into.
@internal
final class WindowsNativeSymbolStubs {
  WindowsNativeSymbolStubs({required this.loadLibraryForDlopen}) {
    _errnoPtr = calloc<Int32>();
    _bindAll();
  }

  /// Loads (or returns an already-loaded) [ElfLoadedLibrary] for the
  /// literal path a bionic `dlopen()` call requests. Owned by the loader
  /// glue (`loader_windows.dart`), so this class stays a pure "symbol
  /// table" independent of how libraries are actually loaded.
  final ElfLoadedLibrary Function(String path) loadLibraryForDlopen;

  final Map<String, Pointer<Void>> _table = {};
  final Map<int, ElfLoadedLibrary> _dlopenHandles = {};
  final WindowsCrt _crt = WindowsCrt();

  /// NativeCallables must outlive every call the loaded library might
  /// make into them (i.e. the whole process); holding them here keeps
  /// their trampoline addresses valid.
  final List<NativeCallable> _keepAlive = [];

  late final Pointer<Int32> _errnoPtr;

  /// Resolves [symbolName] against the stub table, or [nullptr] for
  /// anything outside it.
  ///
  /// Upstream instead installs a hand-assembled trapping trampoline for
  /// unresolved symbols; a null GOT entry gets the same practical
  /// property (a loud crash rather than silently running the wrong host
  /// function) without synthesizing executable stub code from Dart.
  Pointer<Void> resolve(String symbolName) => _table[symbolName] ?? nullptr;

  void _bindAll() {
    _publishCallable(
      'open',
      NativeCallable<Int32 Function(Pointer<Utf8>, Int32)>.isolateLocal(
        _open,
        exceptionalReturn: -1,
      ),
      2,
    );
    _publishCallable(
      'close',
      NativeCallable<Int32 Function(Int32)>.isolateLocal(
        _close,
        exceptionalReturn: -1,
      ),
      1,
    );
    _publishCallable(
      'read',
      NativeCallable<Int32 Function(Int32, Pointer<Void>, Uint32)>.isolateLocal(
        _read,
        exceptionalReturn: -1,
      ),
      3,
    );
    _publishCallable(
      'write',
      NativeCallable<Int32 Function(Int32, Pointer<Void>, Uint32)>.isolateLocal(
        _write,
        exceptionalReturn: -1,
      ),
      3,
    );
    _publishCallable(
      'mkdir',
      NativeCallable<Int32 Function(Pointer<Utf8>, Int32)>.isolateLocal(
        _mkdir,
        exceptionalReturn: -1,
      ),
      2,
    );
    _publishCallable(
      'chmod',
      NativeCallable<Int32 Function(Pointer<Utf8>, Int32)>.isolateLocal(
        _chmod,
        exceptionalReturn: -1,
      ),
      2,
    );
    _publishCallable(
      'ftruncate',
      NativeCallable<Int32 Function(Int64, Int64)>.isolateLocal(
        _ftruncate,
        exceptionalReturn: -1,
      ),
      2,
    );
    _publishCallable(
      'umask',
      NativeCallable<Uint64 Function(Uint64)>.isolateLocal(
        _umask,
        exceptionalReturn: 0,
      ),
      1,
    );
    _publishCallable(
      'lstat',
      NativeCallable<
        Int32 Function(Pointer<Utf8>, Pointer<LinuxStat>)
      >.isolateLocal(_lstat, exceptionalReturn: -1),
      2,
    );
    _publishCallable(
      'fstat',
      NativeCallable<Int32 Function(Int32, Pointer<LinuxStat>)>.isolateLocal(
        _fstat,
        exceptionalReturn: -1,
      ),
      2,
    );
    _publishCallable(
      'gettimeofday',
      NativeCallable<
        Int32 Function(Pointer<LinuxTimeval>, Pointer<Void>)
      >.isolateLocal(_gettimeofday, exceptionalReturn: -1),
      2,
    );
    _publishCallable(
      'malloc',
      NativeCallable<Pointer<Void> Function(IntPtr)>.isolateLocal(_malloc),
      1,
    );
    _publishCallable(
      'free',
      NativeCallable<Void Function(Pointer<Void>)>.isolateLocal(_free),
      1,
    );
    _publishCallable(
      'strncpy',
      NativeCallable<
        Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, IntPtr)
      >.isolateLocal(_strncpy),
      3,
    );

    // Pure-computation libc entry points with no Linux/Windows ABI
    // difference: published straight from the host CRT, no Dart wrapper.
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

    _bindCxxAbi();
    _bindErrno();
    _bindPthreadNoOps();
    _bindAndroidRuntime();
    _bindDynamicLoader();
  }

  /// C++ ABI bits CoreADI references. No-ops are enough: this is a
  /// short-lived process that never needs static destructors to run.
  void _bindCxxAbi() {
    _publishCallable(
      '__cxa_atexit',
      NativeCallable<
        Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>)
      >.isolateLocal(
        (Pointer<Void> _, Pointer<Void> _, Pointer<Void> _) => 0,
        exceptionalReturn: 0,
      ),
      3,
    );
    _publishCallable(
      '__cxa_finalize',
      NativeCallable<Void Function(Pointer<Void>)>.isolateLocal(
        (Pointer<Void> _) {},
      ),
      1,
    );
    // A stack-cookie failure is unrecoverable; abort is the correct
    // (and upstream) response.
    _publish('__stack_chk_fail', _crt.symbol('abort'), 0);
  }

  void _bindErrno() {
    _publishCallable(
      '__errno_location',
      NativeCallable<Pointer<Int32> Function()>.isolateLocal(() => _errnoPtr),
      0,
    );
    // symbols.d's gperf wordlist imports the same function under the
    // name "__errno" as well.
    _table['__errno'] = _table['__errno_location']!;
  }

  /// A single shared no-op for all nine pthread imports, matching
  /// upstream's `emptyStub` (`extern (C) int emptyStub() { return 0; }`).
  ///
  /// Published with argc 0 even though the real functions take arguments:
  /// a function that declares none never touches the incoming argument
  /// registers, so there is nothing for the SysV thunk to marshal.
  void _bindPthreadNoOps() {
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
  }

  void _bindAndroidRuntime() {
    _publishCallable(
      '__system_property_get',
      NativeCallable<Int32 Function(Pointer<Utf8>, Pointer<Utf8>)>.isolateLocal(
        _systemPropertyGet,
        exceptionalReturn: -1,
      ),
      2,
    );
    // Ported from symbols.d's `arc4random_impl`: deliberately a plain,
    // NON-cryptographic source, matching upstream's own std.random
    // choice. Changing it would be a behaviour change, not a fix.
    _publishCallable(
      'arc4random',
      NativeCallable<Uint32 Function()>.isolateLocal(
        () => Random().nextInt(1 << 32),
        exceptionalReturn: 0,
      ),
      0,
    );
  }

  void _bindDynamicLoader() {
    _publishCallable(
      'dlopen',
      NativeCallable<Pointer<Void> Function(Pointer<Utf8>)>.isolateLocal(
        _dlopen,
      ),
      1,
    );
    _publishCallable(
      'dlsym',
      NativeCallable<
        Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>)
      >.isolateLocal(_dlsym),
      2,
    );
    _publishCallable(
      'dlclose',
      NativeCallable<Void Function(Pointer<Void>)>.isolateLocal(_dlclose),
      1,
    );
  }

  void _publish(String name, Pointer<Void> msAbiFn, int argc) {
    _table[name] = SysvAbiBridge.sysvExport(msAbiFn, argc);
  }

  /// Keeps [callable] alive and publishes its trampoline as a
  /// SysV-callable GOT entry. [argc] is the thunk arity the SysV bridge
  /// marshals, and must match the callable's native signature.
  void _publishCallable<T extends Function>(
    String name,
    NativeCallable<T> callable,
    int argc,
  ) {
    _keepAlive.add(callable);
    _publish(name, callable.nativeFunction.cast(), argc);
  }

  /// Host CRT symbol published as a SysV-callable GOT entry.
  void _publishCrt(String name, int argc, [String? crtName]) {
    _publish(name, _crt.symbol(crtName ?? name), argc);
  }

  // --- File system ---

  int _open(Pointer<Utf8> path, int oflag) {
    final winPath = _toWindowsPath(path);
    try {
      final result = _crt.open(winPath, _windowsOpenFlags(oflag));
      if (result < 0) _errnoPtr.value = _enoent;
      return result;
    } finally {
      malloc.free(winPath);
    }
  }

  int _close(int fd) => _crt.close(fd);

  int _read(int fd, Pointer<Void> buf, int count) => _crt.read(fd, buf, count);

  int _write(int fd, Pointer<Void> buf, int count) =>
      _crt.write(fd, buf, count);

  /// The Windows `_mkdir` takes no mode; the requested one is dropped.
  int _mkdir(Pointer<Utf8> path, int mode) {
    final winPath = _toWindowsPath(path);
    try {
      return _crt.mkdir(winPath);
    } finally {
      malloc.free(winPath);
    }
  }

  int _chmod(Pointer<Utf8> path, int mode) {
    final winPath = _toWindowsPath(path);
    try {
      return _crt.chmod(winPath, _windowsChmodMode(mode));
    } finally {
      malloc.free(winPath);
    }
  }

  int _ftruncate(int fd, int length) => _crt.chsize(fd, length);

  /// Upstream returns the argument unchanged rather than tracking a mask.
  int _umask(int mask) => mask;

  int _lstat(Pointer<Utf8> path, Pointer<LinuxStat> out) {
    final winPath = _toWindowsPath(path);
    final buf = calloc<Uint8>(_statScratchSize);
    try {
      final rc = _crt.stat(winPath, buf);
      if (rc != 0) {
        _errnoPtr.value = _enoent;
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
    final buf = calloc<Uint8>(_statScratchSize);
    try {
      final rc = _crt.fstat(fd, buf);
      if (rc != 0) {
        _errnoPtr.value = _ebadf;
        return rc;
      }
      _fillLinuxStat(out, buf);
      return 0;
    } finally {
      calloc.free(buf);
    }
  }

  // --- Time, memory, strings ---

  int _gettimeofday(Pointer<LinuxTimeval> tv, Pointer<Void> tz) {
    final now = DateTime.now().toUtc();
    tv.ref
      ..tv_sec = now.millisecondsSinceEpoch ~/ 1000
      ..tv_usec = (now.millisecondsSinceEpoch % 1000) * 1000;
    return 0;
  }

  Pointer<Void> _malloc(int size) => _crt.malloc(size);

  void _free(Pointer<Void> ptr) => _crt.free(ptr);

  Pointer<Utf8> _strncpy(Pointer<Utf8> dest, Pointer<Utf8> src, int n) =>
      _crt.strncpy(dest, src, n);

  /// Ported from symbols.d's `__system_property_get_impl`: always reports
  /// a fixed placeholder "serial number", verbatim — including *not*
  /// NUL-terminating the output. Upstream doesn't either; callers are
  /// expected to use the returned length.
  static int _systemPropertyGet(Pointer<Utf8> _, Pointer<Utf8> value) {
    const placeholder = 'no s/n number';
    final bytes = ascii.encode(placeholder);
    value.cast<Uint8>().asTypedList(bytes.length).setAll(0, bytes);
    return bytes.length;
  }

  // --- dlopen/dlsym/dlclose emulation ---
  //
  // Ported from symbols.d's dlopenWrapper/dlsymWrapper/dlcloseWrapper.
  // Upstream additionally identifies the *calling* library by inspecting
  // the return address on the stack (`rootLibrary()`), purely to
  // propagate a `hooks` override map and to track the child for a D
  // destructor. ADI never supplies `hooks`, and this short-lived process
  // has no equivalent deterministic destructor, so both are dropped
  // rather than reimplementing return-address stack inspection in Dart.

  Pointer<Void> _dlopen(Pointer<Utf8> namePtr) {
    final path = namePtr.toDartString();
    try {
      final lib = loadLibraryForDlopen(path);
      // Opaque heap handle — never return the ELF mapping address. ADI
      // may treat the dlopen result like a malloc'd object in edge
      // paths; handing it the VirtualAlloc base has been a crash suspect
      // after dlsym.
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
    // ponytail: the sub-library's pages are not unmapped on close — this
    // is a short-lived, single-shot provisioning client. Add real
    // VirtualFree-on-close (via the NativeMemoryAllocator) if this loader
    // is ever reused in a long-lived process that opens and closes
    // libraries repeatedly.
  }
}

/// Scratch buffer handed to `_stat64`/`_fstat64`, generously sized past
/// the 56 bytes we actually read back.
const int _statScratchSize = 64;

const int _enoent = 2;
const int _ebadf = 9;
