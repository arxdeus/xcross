import 'dart:ffi';
import 'dart:typed_data';

import 'package:apple_developer_kit/src/adi/adi_architecture.dart';
import 'package:apple_developer_kit/src/adi/elf/elf_loaded_library.dart';
import 'package:apple_developer_kit/src/adi/loader/internal/memory_allocator.dart';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

import 'support/elf_fixture.dart';

final class RecordingAllocator implements NativeMemoryAllocator {
  RecordingAllocator(this.pageSize);

  @override
  final int pageSize;
  Pointer<Uint8>? allocated;
  bool freed = false;
  bool flushed = false;
  final protections = <(int, int, bool, bool, bool)>[];

  @override
  NativeMemoryBlock alloc(int size) {
    allocated = calloc<Uint8>(size + pageSize);
    final aligned = (allocated!.address + pageSize - 1) & ~(pageSize - 1);
    return NativeMemoryBlock(Pointer.fromAddress(aligned), size);
  }

  @override
  void free(NativeMemoryBlock block) {
    calloc.free(allocated!);
    allocated = null;
    freed = true;
  }

  void dispose() {
    if (allocated != null) calloc.free(allocated!);
    allocated = null;
  }

  @override
  void flushInstructionCache(NativeMemoryBlock block) => flushed = true;

  @override
  void protect(
    NativeMemoryBlock block, {
    required int offset,
    required int length,
    required bool readable,
    required bool writable,
    required bool executable,
  }) {
    expect(flushed, isTrue);
    expect(offset % pageSize, 0);
    expect(length % pageSize, 0);
    expect(writable && executable, isFalse);
    protections.add((offset, length, readable, writable, executable));
  }
}

void main() {
  final machine = AdiArchitecture.forAbi(Abi.current()).elfMachine;
  for (final pageSize in [4096, 16384, 65536]) {
    for (final base in [0, 0x1000, 0x10000]) {
      test(
        'relocations, load bias and W^X on $pageSize-byte pages at $base',
        () {
          final allocator = RecordingAllocator(pageSize);
          addTearDown(allocator.dispose);
          final library = ElfLoadedLibrary.load(
            elfFixture(machine, base: base),
            allocator,
            (name) {
              expect(name, 'external');
              return Pointer.fromAddress(0x12340000);
            },
          );
          final target = library.lookup('export').cast<Uint64>();
          expect(target[0], target.address + 0x100);
          expect(target[1], target.address - 0xf00 + 3);
          expect(target[2], machine == 183 ? 0x12340005 : 0x12340000);
          expect(target[3], machine == 183 ? 0x12340007 : 0x12340000);
          expect(target[4], 0);
          expect(allocator.flushed, isTrue);
          expect(allocator.protections.any((p) => p.$5), isTrue);
          expect(allocator.protections.any((p) => p.$4), isTrue);
          expect(() => library.lookup('external'), throwsStateError);
        },
      );
    }
  }

  test('absolute symbol values are not rebased', () {
    final allocator = RecordingAllocator(4096);
    addTearDown(allocator.dispose);
    final bytes = elfFixture(machine);
    final data = ByteData.sublistView(bytes);
    data.setUint16(0x400 + 3 * 24 + 6, 0xfff1, Endian.little);
    data.setUint64(0x400 + 3 * 24 + 8, 0x87654320, Endian.little);
    final library = ElfLoadedLibrary.load(bytes, allocator, (_) => nullptr);
    expect(library.lookup('local').address, 0x87654320);
    expect(library.lookup('export').cast<Uint64>()[1], 0x87654323);
  });

  test('rejects defined symbols outside the image', () {
    final allocator = RecordingAllocator(4096);
    addTearDown(allocator.dispose);
    final bytes = elfFixture(machine);
    ByteData.sublistView(
      bytes,
    ).setUint64(0x400 + 3 * 24 + 8, 0xffff0000, Endian.little);
    expect(
      () => ElfLoadedLibrary.load(bytes, allocator, (_) => nullptr),
      throwsFormatException,
    );
    expect(allocator.freed, isTrue);
  });

  test(
    'rejects relocation offset overflow without writing outside the image',
    () {
      final allocator = RecordingAllocator(4096);
      addTearDown(allocator.dispose);
      final bytes = elfFixture(machine);
      ByteData.sublistView(
        bytes,
      ).setUint64(0x600, (0x7fffffff << 32) | 0xfffffff8, Endian.little);
      expect(
        () => ElfLoadedLibrary.load(bytes, allocator, (_) => nullptr),
        throwsFormatException,
      );
      expect(allocator.freed, isTrue);
    },
  );

  test('rejects overflowing program-header bounds before allocating', () {
    final allocator = RecordingAllocator(4096);
    final bytes = elfFixture(machine);
    final data = ByteData.sublistView(bytes);
    data.setUint64(64 + 16, (0x7fffffff << 32) | 0xfffff000, Endian.little);
    data.setUint64(64 + 40, 0x1000, Endian.little);
    expect(
      () => ElfLoadedLibrary.load(bytes, allocator, (_) => nullptr),
      throwsFormatException,
    );
    expect(allocator.allocated, isNull);
  });

  test('rejects foreign machine before allocating', () {
    final allocator = RecordingAllocator(4096);
    expect(
      () => ElfLoadedLibrary.load(
        elfFixture(machine == 183 ? 62 : 183),
        allocator,
        (_) => nullptr,
      ),
      throwsFormatException,
    );
    expect(allocator.allocated, isNull);
  });

  for (final mutation in ['relocation', 'target', 'symbol', 'rela size']) {
    test('rejects invalid $mutation and frees memory', () {
      final allocator = RecordingAllocator(4096);
      addTearDown(allocator.dispose);
      final bytes = elfFixture(machine);
      final data = ByteData.sublistView(bytes);
      switch (mutation) {
        case 'relocation':
          data.setUint64(0x608, 9999, Endian.little);
        case 'target':
          data.setUint64(0x600, 0x9000, Endian.little);
        case 'symbol':
          data.setUint64(
            0x608,
            (100 << 32) | (machine == 183 ? 1027 : 8),
            Endian.little,
          );
        case 'rela size':
          data.setUint64(0x200 + 3 * 64 + 32, 121, Endian.little);
      }
      expect(
        () => ElfLoadedLibrary.load(bytes, allocator, (_) => nullptr),
        throwsA(anyOf(isA<FormatException>(), isA<UnsupportedError>())),
      );
      expect(allocator.freed, isTrue);
    });
  }

  test('rejects incompatible page permissions before allocating', () {
    final allocator = RecordingAllocator(16384);
    final bytes = elfFixture(machine);
    ByteData.sublistView(bytes).setUint32(68, 7, Endian.little);
    expect(
      () => ElfLoadedLibrary.load(bytes, allocator, (_) => nullptr),
      throwsUnsupportedError,
    );
    expect(allocator.allocated, isNull);
  });
}
