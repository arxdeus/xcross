# NOTICE

`provision_dart` is a Dart port of parts of
[Provision](https://github.com/Dadoum/Provision) by Dadoum, licensed under
the GNU Library General Public License, version 2 (LGPLv2). See `LICENSE`
for the full license text.

This package as a whole is distributed under LGPLv2.

## Ported files

| This package                                     | Ported from (upstream)                                                                                  | Notes |
|---------------------------------------------------|-----------------------------------------------------------------------------------------------------------|-------|
| `lib/src/adi_bindings.dart`                        | `lib/provision/adi.d` — the `ADI*_t` function pointer `alias`es and the obfuscated native symbol names (`kq56gsgHG6`, `Sph98paBcz`, etc.) used to `load()` them | 1:1 signature and symbol-name port |
| `lib/src/adi_client.dart`                          | `lib/provision/adi.d` — `class ADI`'s public methods, and the `ADIError` enum / `toString(ADIError)` message table / `ADIException` | Idiomatic Dart wrapper; native buffers are copy-then-dispose instead of upstream's RAII structs |
| `lib/src/elf/elf_reader.dart`, `lib/src/elf/elf_loaded_library.dart` | `lib/provision/androidlibrary.d` — the `AndroidLibrary` class: ELF64 header/program-header/section-header/symbol-table parsing, `SHT_RELA` relocation processing (`R_X86_64_RELATIVE`/`GLOB_DAT`/`JUMP_SLOT`/`_64`), and the SysV `.hash` / GNU `.gnu.hash` symbol lookup algorithms (`ElfHashTable`, `GnuHashTable`) | See "What was ported this round" below |
| `lib/src/loader/native_symbol_stubs.dart`          | `lib/provision/symbols.d` (the fixed 29-symbol stub table, `dlopenWrapper`/`dlsymWrapper`/`dlcloseWrapper`) and `lib/provision/compat/linux.d` (the real-libc pass-through bindings) | Linux only for now — see "Known limitation" below |
| `lib/src/loader/loader_posix.dart`, `lib/src/loader/memory_allocator_posix.dart` | Structural equivalent of `AndroidLibrary`'s `mmap`/`mprotect` usage in androidlibrary.d, and the load-order role of `ADILoadLibraryWithPath` | Split per this task's requested architecture: platform-independent ELF core + a small platform-specific memory allocator |

`lib/provision/compat/general.d` was also fetched and reviewed: on POSIX
it contributes no behavior of its own (`androidInvoke` is a no-op
passthrough, `sysv` an empty UDA — both matter only for Windows' distinct
calling convention). Nothing from it needed porting here.

## Original code (not a port of any upstream file)

- `lib/src/apk_fetch.dart` — automates the manual step documented in
  upstream's `README.md` ("Dependencies": download the Apple Music APK
  and extract `lib/x86_64/libCoreADI.so` + `lib/x86_64/libstoreservicescore.so`
  next to the executable). Upstream does not perform this download/extract
  step at runtime in D. Additionally records the downloaded APK's SHA-256
  next to it (`applemusic.apk.sha256`) so a future Apple Music version
  bump is at least detectable, rather than silently changing behavior.
- `lib/src/loader/loader.dart`, `lib/src/loader/memory_allocator.dart` —
  the loader/allocator interfaces themselves (upstream has no equivalent
  abstraction layer; it's a single concrete `AndroidLibrary` class used
  everywhere). Added so a future Windows implementation
  (`lib/src/loader/loader_windows.dart`, currently a stub) can reuse the
  platform-independent ELF core without touching it.

## What was ported this round (replacing the Phase 1 `dlopen` mistake)

An earlier version of this package used `dart:ffi`'s
`DynamicLibrary.open()` (a plain `dlopen()`) to load the two native
libraries. **This was confirmed to be actively unsafe, not merely
unverified**: upstream's own symbol table
(`lib/provision/symbols.d`) stubs out `pthread_mutex_lock`, `pthread_once`,
and six other `pthread_*` functions as no-ops specifically because
bionic's `pthread_mutex_t`/`pthread_once_t` are ~4 bytes while glibc's are
~40 bytes. A plain `dlopen()` resolves those same-named imports to the
*real* glibc implementations, which then read/write a struct field sized
for 4 bytes as if it were ~40 — silent heap/stack corruption, not a clean
failure, the moment the loaded library calls any of those functions.

This has been replaced with a faithful port of upstream's own loading
strategy: `AndroidLibrary` (→ `ElfLoadedLibrary`) manually `mmap`s each
`.so`, walks its ELF program headers, copies each `PT_LOAD` segment into
place, and resolves every relocation itself against a fixed, 29-entry
stub table (→ `NativeSymbolStubs`) ported from `symbols.d` — never
against the host's real libc for the symbols that matter (pthreads).
Everyday POSIX calls the loaded library also imports (`open`, `read`,
`malloc`, `gettimeofday`, etc.) are still safe to forward straight to the
real host libc on Linux, because those operate on kernel-ABI structures
bionic and glibc agree on; only the userspace-library-specific structs
(pthread types) differ and need stubbing.

The `dlopen`/`dlsym`/`dlclose` entries in the same 29-symbol table are
also ported (`native_symbol_stubs.dart`'s `_dlopen`/`_dlsym`/`_dlclose`,
via `NativeCallable`): `adi.d`'s own D caller never loads `libCoreADI.so`
directly, only `libstoreservicescore.so` — this strongly implies
`libCoreADI.so` is pulled in lazily by `libstoreservicescore.so` calling
`dlopen()` internally at runtime, which this loader now intercepts and
emulates recursively, rather than the earlier (incorrect) assumption that
`libCoreADI.so` needed to be preloaded by the Dart caller in ELF
`DT_NEEDED` dependency order.

### Deliberate simplifications vs. upstream (all flagged, not silent)

- **Unresolved-symbol sentinel**: upstream throws a D exception the
  instant a truly-unresolved import is called, via a hand-assembled
  x86_64 trampoline (`version(StubMaps)`'s `buildStub`). Reproducing that
  from Dart would mean assembling and executing raw trap machine code.
  Instead, an unresolved symbol resolves to a null-pointer GOT/PLT entry
  — if ever actually called, this crashes loudly (SIGSEGV) rather than
  running the wrong, wrongly-sized real host function, which is the same
  *practical* safety property with much less implementation risk.
- **`dlopen` "caller" tracking**: upstream's `dlopenWrapper` determines
  which `AndroidLibrary` is calling it by inspecting the return address
  on the stack (`rootLibrary()`), purely to propagate an optional `hooks`
  override map and to track the sub-library for cleanup in a D
  destructor. ADI never supplies `hooks` (always null upstream), and this
  is a short-lived process with no destructor-based cleanup to mirror
  anyway — both were dropped rather than reimplementing stack-based
  caller detection from Dart.
- **Page-size "shift" compensation**: upstream compensates for hosts
  whose native page size exceeds the ELF's assumed 4 KiB segment
  alignment (relevant on e.g. 16 KiB-page aarch64 hosts). Not reachable
  on our target (only an x86_64 host can execute the x86_64 machine code
  we're loading, and x86_64 hosts universally use 4 KiB pages) — not
  ported. See the `ponytail:` comment in `elf_loaded_library.dart`.
- **`dlopen` path resolution fallback**: upstream does a completely
  literal, unmodified file open of whatever string the loaded library
  passes to `dlopen()` — no search path at all. This port additionally
  tries the last explicitly-loaded directory as a fallback if a bare
  filename isn't found as given. This is a labeled addition, not
  something confirmed from upstream's behavior — see the `ponytail:`
  comment in `loader_posix.dart` and the "Needs verification" note below.

## LGPLv2 obligations

Per LGPLv2 §2, the ported files above remain licensed under LGPLv2 as part
of this library; upstream's copyright and license notices are preserved
via this NOTICE and the accompanying `LICENSE` file. Anyone modifying the
ported files must keep them LGPLv2-licensed and note what was changed, per
the license terms.

## Known limitation (flagged for review — read before trusting this with real credentials)

**Linux only.** `PosixNativeLibraryLoader` refuses to construct on
anything but Linux. The direct pass-through libc bindings in
`native_symbol_stubs.dart` (`open`, `lstat`, `fstat`, etc.) forward
straight to the host's real libc, which is safe on Linux (bionic and
glibc agree on the kernel `struct stat`/`open()` flag ABI there) but would
NOT be safe on macOS: Darwin's `open()` flag bit values and `struct stat`
layout both differ from Linux's. Upstream handles this with per-call
translation in `lib/provision/compat/macos.d`, which was *not* fetched or
ported this round. Shipping this on macOS without porting that translation
first would risk the exact same class of silent-corruption bug this
loader exists to avoid — just via `stat`/`open` instead of `pthread_*`.
Port `compat/macos.d` before re-enabling macOS support.

**Not validated under memory-safety tooling.** This manual ELF loader
(program header copying, protection flipping, and hand-rolled RELA
relocation application) has **not** been run against the real extracted
`libCoreADI.so`/`libstoreservicescore.so` under ASan or valgrind, or on
any real Linux machine at all — the dev box used to write this is
Windows, which cannot execute this code path at all (there is no ELF
loader to test against). Given this handles real Apple ID credential
provisioning, running the full loader (including the `dlopen` emulation
path, which has the least amount of real-world precedent to lean on)
under a memory checker on real Linux hardware, with the real two
libraries, is required before this package is trusted with real
credentials — this is now a "confirm the port is correct and
memory-safe" gate, not the previous phase's "confirm whether `dlopen`
happens to work" gate.
