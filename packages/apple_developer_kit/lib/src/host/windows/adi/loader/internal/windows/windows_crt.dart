// Host CRT (ucrtbase, already mapped into this process) entry points the
// Windows stub table forwards to.
//
// Every name here is the MSVC CRT spelling, which differs from the POSIX
// one the loaded Android library imports: `open` -> `_open`, `ftruncate`
// -> `_chsize_s`, `lstat` -> `_stat64`, `fstat` -> `_fstat64`.

part of '../native_symbol_stubs_windows.dart';

final class WindowsCrt {
  final DynamicLibrary _process = DynamicLibrary.process();

  /// Raw address of CRT symbol [name], for entries published straight
  /// into the ELF GOT with no Dart-side wrapper.
  Pointer<Void> symbol(String name) => _process.lookup<Void>(name).cast();

  late final int Function(Pointer<Utf8>, int) open = _process
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Int32),
        int Function(Pointer<Utf8>, int)
      >('_open');

  late final int Function(int) close = _process
      .lookupFunction<Int32 Function(Int32), int Function(int)>('_close');

  late final int Function(int, Pointer<Void>, int) read = _process
      .lookupFunction<
        Int32 Function(Int32, Pointer<Void>, Uint32),
        int Function(int, Pointer<Void>, int)
      >('_read');

  late final int Function(int, Pointer<Void>, int) write = _process
      .lookupFunction<
        Int32 Function(Int32, Pointer<Void>, Uint32),
        int Function(int, Pointer<Void>, int)
      >('_write');

  late final int Function(Pointer<Utf8>) mkdir = _process
      .lookupFunction<
        Int32 Function(Pointer<Utf8>),
        int Function(Pointer<Utf8>)
      >('_mkdir');

  late final int Function(Pointer<Utf8>, int) chmod = _process
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Int32),
        int Function(Pointer<Utf8>, int)
      >('_chmod');

  /// `ftruncate` equivalent.
  late final int Function(int, int) chsize = _process
      .lookupFunction<Int32 Function(Int32, Int64), int Function(int, int)>(
        '_chsize_s',
      );

  /// `lstat` equivalent; writes an MSVC `struct __stat64`.
  late final int Function(Pointer<Utf8>, Pointer<Uint8>) stat = _process
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Pointer<Uint8>),
        int Function(Pointer<Utf8>, Pointer<Uint8>)
      >('_stat64');

  late final int Function(int, Pointer<Uint8>) fstat = _process
      .lookupFunction<
        Int32 Function(Int32, Pointer<Uint8>),
        int Function(int, Pointer<Uint8>)
      >('_fstat64');

  late final Pointer<Void> Function(int) malloc = _process
      .lookupFunction<
        Pointer<Void> Function(IntPtr),
        Pointer<Void> Function(int)
      >('malloc');

  late final void Function(Pointer<Void>) free = _process
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('free');

  late final Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, int) strncpy =
      _process.lookupFunction<
        Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, IntPtr),
        Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, int)
      >('strncpy');
}
