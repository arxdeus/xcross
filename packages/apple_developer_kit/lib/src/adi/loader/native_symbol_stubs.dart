// Ported from Provision's lib/provision/symbols.d (the fixed table of the
// ~29 imported symbols this loader resolves against its own stubs
// instead of the host libc) plus the POSIX-side real-libc bindings in
// lib/provision/compat/linux.d (https://github.com/Dadoum/Provision,
// LGPLv2 — see LICENSE/NOTICE.md). `compat/general.d` was also fetched
// and reviewed: on POSIX it contributes no behavior of its own
// (`androidInvoke` is a no-op passthrough and `sysv` an empty UDA there —
// both only matter for Windows' distinct calling convention), so nothing
// from it needed porting here.
//
// IMPORTANT — DO NOT "IMPROVE" THE PTHREAD STUBS: they are deliberately
// no-ops, matching upstream exactly (`emptyStub` in symbols.d). Bionic's
// `pthread_mutex_t`/`pthread_once_t` are ~4 bytes; glibc's are ~40 bytes.
// If a real glibc pthread function ran against a bionic-sized struct
// field inside the loaded library's own memory, it would silently write
// past the field's actual size, corrupting adjacent memory. That silent
// corruption is exactly why this whole custom loader exists instead of a
// plain `dlopen()` — see NOTICE.md.
//
// NOTE — Linux only for now: the direct pass-through bindings below
// (open/lstat/fstat/etc., ported from compat/linux.d) forward straight
// to the *host's* real libc. On Linux this is safe because the kernel's
// `struct stat`/`open()` flag values are the same ABI bionic itself
// targets. On macOS neither holds (Darwin's `open()` flag bits and
// `struct stat` layout both differ from Linux's) — upstream handles this
// with per-call translation in `compat/macos.d`, which was not fetched
// or ported this round. Loading on macOS with this file as-is would risk
// the exact same class of silent-corruption bug this loader exists to
// avoid, just via stat/open instead of pthreads. `PosixNativeLibraryLoader`
// therefore refuses to run on anything but Linux until macos.d is ported
// — see NOTICE.md.

import 'dart:convert';
import 'dart:ffi';
import 'dart:math';

import 'package:apple_developer_kit/src/adi/elf/elf_loaded_library.dart';
import 'package:ffi/ffi.dart';

/// Builds the fixed 29-entry stub-symbol table Android/bionic-targeted
/// libraries are relocated against, and hosts the recursive "dlopen
/// emulation" used to load one manually-loaded library from within
/// another (ported from `dlopenWrapper`/`dlsymWrapper`/`dlcloseWrapper`
/// in symbols.d — this is how `libstoreservicescore.so` is expected to
/// pull in `libCoreADI.so` at runtime; adi.d's own D caller never loads
/// `libCoreADI.so` directly. See NOTICE.md for the load-order note).
class NativeSymbolStubs {
  NativeSymbolStubs({required this.loadLibraryForDlopen}) {
    _bindLibcPassthroughs();
    _bindPthreadNoOps();
    _bindAndroidRuntime();
    _bindDynamicLoader();
  }

  /// Loads (or returns an already-loaded) [ElfLoadedLibrary] for the
  /// literal path a bionic `dlopen()` call requests. Owned by the loader
  /// glue (`loader_posix.dart`), not here, so this class stays a pure
  /// "symbol table" independent of how libraries are actually loaded.
  final ElfLoadedLibrary Function(String path) loadLibraryForDlopen;

  final Map<String, Pointer<Void>> _table = {};
  final Map<int, ElfLoadedLibrary> _dlopenHandles = {};

  /// NativeCallables must be kept alive for as long as the loaded library
  /// might call into them (i.e. for the lifetime of this process);
  /// storing them here prevents them from being garbage-collected and
  /// the trampoline address becoming invalid.
  final List<NativeCallable> _keepAlive = [];

  /// Resolves [symbolName] against the stub table.
  ///
  /// Returns [nullptr] (not `null`) for anything outside upstream's fixed
  /// 29-symbol table — a deliberate divergence: upstream's fallback
  /// throws a D exception the instant the *loaded* library calls the
  /// unresolved symbol (`undefinedSymbol`, built via a hand-assembled
  /// x86_64 trampoline under `version(StubMaps)`). Reproducing that
  /// exactly from Dart would mean assembling and executing raw trap
  /// machine code ourselves, which is out of scope here. A null-pointer
  /// GOT/PLT entry gets the same *practical* safety property (a loud
  /// crash — SIGSEGV — if the unresolved symbol is ever actually called,
  /// instead of silently running the wrong, wrongly-sized real host
  /// function) without needing to synthesize executable stub code.
  Pointer<Void> resolve(String symbolName) => _table[symbolName] ?? nullptr;

  /// Direct pass-throughs to the host's real libc, ported from
  /// compat/linux.d's `alias x = core.sys.posix....x;` bindings. (D's
  /// `traceCall!` wrapper there only adds a debug log line — not
  /// behavior — and was intentionally not ported.)
  void _bindLibcPassthroughs() {
    final libc = DynamicLibrary.process();
    for (final name in const [
      'open',
      'close',
      'read',
      'write',
      'mkdir',
      'chmod',
      'ftruncate',
      'umask',
      'lstat',
      'fstat',
      'gettimeofday',
      'malloc',
      'free',
      'strncpy',
      '__errno_location',
    ]) {
      _table[name] = libc.lookup<NativeFunction<Void Function()>>(name).cast();
    }
    // symbols.d's gperf wordlist imports this one under the name
    // "__errno" (not "__errno_location") but binds it to the same
    // function (`&__errno_location` per compat/linux.d) — ported as such.
    _table['__errno'] = _table['__errno_location']!;
  }

  /// A single shared no-op stub for all nine pthread imports, ignoring
  /// whatever arguments were actually passed. Matches `emptyStub` in
  /// symbols.d exactly (`extern (C) int emptyStub() { return 0; }`),
  /// reused as-is for every `pthread_*` entry in D's own wordlist. Safe
  /// because the incoming argument registers are simply never touched by
  /// a function that takes none.
  void _bindPthreadNoOps() {
    final emptyStub = NativeCallable<Int32 Function()>.isolateLocal(
      _emptyStub,
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
      _table[name] = emptyStub.nativeFunction.cast();
    }
  }

  void _bindAndroidRuntime() {
    _bind(
      '__system_property_get',
      NativeCallable<Int32 Function(Pointer<Utf8>, Pointer<Utf8>)>.isolateLocal(
        _systemPropertyGet,
        exceptionalReturn: -1,
      ),
    );
    _bind(
      'arc4random',
      NativeCallable<Uint32 Function()>.isolateLocal(
        _arc4random,
        exceptionalReturn: 0,
      ),
    );
  }

  void _bindDynamicLoader() {
    _bind(
      'dlopen',
      NativeCallable<Pointer<Void> Function(Pointer<Utf8>)>.isolateLocal(
        _dlopen,
      ),
    );
    _bind(
      'dlsym',
      NativeCallable<
        Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>)
      >.isolateLocal(_dlsym),
    );
    _bind(
      'dlclose',
      NativeCallable<Void Function(Pointer<Void>)>.isolateLocal(_dlclose),
    );
  }

  /// Keeps [callable] alive and publishes its trampoline under [name].
  void _bind<T extends Function>(String name, NativeCallable<T> callable) {
    _keepAlive.add(callable);
    _table[name] = callable.nativeFunction.cast();
  }

  static int _emptyStub() => 0;

  /// Ported from symbols.d's `__system_property_get_impl`: always reports
  /// a fixed placeholder "serial number", verbatim — including *not*
  /// NUL-terminating the output. Upstream doesn't either; callers are
  /// expected to use the returned length rather than rely on a NUL.
  static int _systemPropertyGet(Pointer<Utf8> _, Pointer<Utf8> value) {
    const placeholder = 'no s/n number';
    final bytes = ascii.encode(placeholder);
    value.cast<Uint8>().asTypedList(bytes.length).setAll(0, bytes);
    return bytes.length;
  }

  /// Ported from symbols.d's `arc4random_impl`: a plain (non-CSPRNG)
  /// random source, matching upstream's own (also non-cryptographic)
  /// choice of D's `std.random.Random` — not "improved" to a secure RNG
  /// here since that would be a behavior change beyond what was asked.
  static int _arc4random() => Random().nextInt(1 << 32);

  // --- dlopen/dlsym/dlclose emulation ---
  //
  // Ported from symbols.d's dlopenWrapper/dlsymWrapper/dlcloseWrapper,
  // simplified vs. upstream in one way: upstream determines a "caller"
  // library by inspecting the return address on the call stack
  // (`rootLibrary()`), purely to (a) propagate its `hooks` override map
  // to the newly loaded library and (b) track it in the caller's
  // `loadedLibraries` for cleanup in a D destructor. ADI never supplies
  // `hooks` (always null), and this is a short-lived, single-purpose
  // process with no equivalent deterministic destructor to mirror (b)
  // with anyway, so both are dropped rather than reimplementing
  // return-address stack inspection from Dart.

  Pointer<Void> _dlopen(Pointer<Utf8> namePtr) {
    final path = namePtr.toDartString();
    try {
      final lib = loadLibraryForDlopen(path);
      final handle = lib.base;
      _dlopenHandles[handle.address] = lib;
      return handle;
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
    // ponytail: real unmapping of the sub-library's pages on close is
    // skipped — this is a short-lived, single-shot provisioning client
    // where the whole process exits shortly after. Add real munmap-on-
    // close (via the NativeMemoryAllocator) if this loader is ever reused
    // in a long-lived process that opens/closes libraries repeatedly.
  }
}
