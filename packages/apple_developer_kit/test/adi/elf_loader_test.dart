import 'dart:ffi';
import 'dart:typed_data';

import 'package:apple_developer_kit/src/host/shared/adi/elf/elf_code_preparation.dart';
import 'package:apple_developer_kit/src/host/shared/adi/elf/elf_loaded_library.dart';
import 'package:apple_developer_kit/src/host/shared/adi/loader/internal/memory_allocator.dart';
import 'package:apple_developer_kit/src/shared/adi/adi_architecture.dart';
import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';
import 'package:test/test.dart';

import 'support/elf_fixture.dart';

@internal
final class RecordingAllocator implements NativeMemoryAllocator {
  RecordingAllocator(this._pageSize);

  final int _pageSize;
  int pageSizeReads = 0;
  @override
  int get pageSize {
    pageSizeReads++;
    return _pageSize;
  }

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
  for (final machine in [62, 183]) {
    for (final size in [0, 16]) {
      test(
        'skips $machine ${size == 0 ? 'empty code' : 'data-only'} sections',
        () {
          final allocator = RecordingAllocator(4096);
          addTearDown(allocator.dispose);
          final bytes = elfFixture(machine);
          final data = ByteData.sublistView(bytes);
          for (final section in [0x300, 0x340]) {
            data.setUint64(section + 8, size == 0 ? 6 : 2, Endian.little);
            data.setUint64(section + 32, size, Endian.little);
          }
          ElfLoadedLibrary.load(
            bytes,
            allocator,
            (_) => nullptr,
            machine: machine,
            codePreparation: CallbackElfCodePreparation((_, _) {
              fail('Only nonempty executable sections may be prepared.');
            }),
          );
          expect(allocator.flushed, isTrue);
        },
      );
    }

    for (final pageSize in [4096, 16384, 65536]) {
      test(
        'prepares copied and relocated code for $machine on $pageSize pages',
        () {
          final allocator = RecordingAllocator(pageSize);
          addTearDown(allocator.dispose);
          final bytes = elfFixture(machine);
          final data = ByteData.sublistView(bytes);
          data.setUint64(0x600, 0x1100, Endian.little);
          bytes.fillRange(0x1108, 0x1110, 0xa5);
          bytes.fillRange(0x1180, 0x1188, 0x5a);
          bytes.fillRange(0x1200, 0x1220, 0x37);
          bytes.fillRange(0x2800, 0x3000, 0xee);
          final regions = <(int, int)>[];
          final library = ElfLoadedLibrary.load(
            bytes,
            allocator,
            (_) => Pointer.fromAddress(0x12340000),
            machine: machine,
            codePreparation: CallbackElfCodePreparation((code, length) {
              expect(allocator.flushed, isFalse);
              expect(allocator.protections, isEmpty);
              if (regions.isEmpty) {
                expect(length, 16);
                expect(code.cast<Uint64>().value, code.address + 0x1000);
                expect(code.asTypedList(length).sublist(8), everyElement(0xa5));
                data.setUint64(0x340 + 16, 0xffff0000, Endian.little);
                data.setUint64(0x340 + 32, 0x100000, Endian.little);
              } else {
                expect(length, 8);
                expect(code.address, regions.single.$1 + 0x80);
                expect(code.asTypedList(length), everyElement(0x5a));
              }
              regions.add((code.address, length));
              code[length - 1] = 0x7b;
            }),
          );
          final local = library.lookup('local').cast<Uint8>();
          expect(regions, [(local.address, 16), (local.address + 0x80, 8)]);
          expect(local[15], 0x7b);
          expect(local[0x87], 0x7b);
          expect((local + 0x100).asTypedList(32), everyElement(0x37));
          expect((local + 0x1700).asTypedList(0x800), everyElement(0));
          expect(allocator.flushed, isTrue);
          expect(allocator.protections, isNotEmpty);
        },
      );
    }

    test(
      'preparation failure frees $machine allocation before flush or protect',
      () {
        final allocator = RecordingAllocator(4096);
        addTearDown(allocator.dispose);
        var calls = 0;
        final failure = StateError('preparation failed');
        expect(
          () => ElfLoadedLibrary.load(
            elfFixture(machine),
            allocator,
            (_) => nullptr,
            machine: machine,
            codePreparation: CallbackElfCodePreparation((code, length) {
              calls++;
              code[0] = 0x12;
              throw failure;
            }),
          ),
          throwsA(same(failure)),
        );
        expect(calls, 1);
        expect(allocator.freed, isTrue);
        expect(allocator.allocated, isNull);
        expect(allocator.flushed, isFalse);
        expect(allocator.protections, isEmpty);
      },
    );

    for (final mutation in [
      'unallocated',
      'writable',
      'tls',
      'compressed',
      'bss',
      'wrong type',
      'nonexecutable segment',
      'outside segment',
      'file offset mismatch',
      'file overflow',
      'address overflow',
      'unsigned address',
      'size overflow',
      'unsigned size',
      'file-backed tail',
      'overlapping code',
      'overlapping data',
      'overlapping bss',
      'conflicting segment',
    ]) {
      test('rejects $machine $mutation metadata before all effects', () {
        final allocator = RecordingAllocator(4096);
        addTearDown(allocator.dispose);
        final bytes = elfFixture(machine);
        final data = ByteData.sublistView(bytes);
        void u64(int offset, int value) =>
            data.setUint64(offset, value, Endian.little);
        switch (mutation) {
          case 'unallocated':
            u64(0x308, 4);
          case 'writable':
            u64(0x308, 7);
          case 'tls':
            u64(0x308, 0x406);
          case 'compressed':
            u64(0x308, 0x806);
          case 'bss':
            data.setUint32(0x304, 8, Endian.little);
          case 'wrong type':
            data.setUint32(0x304, 3, Endian.little);
          case 'nonexecutable segment':
            data.setUint32(68, 4, Endian.little);
          case 'outside segment':
            u64(0x310, 0x9000);
          case 'file offset mismatch':
            u64(0x318, 0x1101);
          case 'file overflow':
            u64(0x318, 0x2fff);
          case 'address overflow':
            u64(0x310, (0x7fffffff << 32) | 0xfffffff8);
          case 'unsigned address':
            u64(0x310, -1);
          case 'size overflow':
            u64(0x320, (0x7fffffff << 32) | 0xffffffff);
          case 'unsigned size':
            u64(0x320, -1);
          case 'file-backed tail':
            u64(64 + 32, 0x108);
          case 'overlapping code':
            u64(0x350, 0x1108);
            u64(0x358, 0x1108);
          case 'overlapping data':
            u64(0x390, 0x1108);
          case 'overlapping bss':
            u64(0x3d0, 0x1108);
          case 'conflicting segment':
            u64(64 + 56 + 16, 0x1100);
        }
        var resolved = false;
        var prepared = false;
        expect(
          () => ElfLoadedLibrary.load(
            bytes,
            allocator,
            (_) {
              resolved = true;
              return nullptr;
            },
            machine: machine,
            codePreparation: CallbackElfCodePreparation(
              (_, _) => prepared = true,
            ),
          ),
          throwsFormatException,
        );
        expect(allocator.pageSizeReads, 0);
        expect(allocator.allocated, isNull);
        expect(allocator.freed, isFalse);
        expect(allocator.flushed, isFalse);
        expect(allocator.protections, isEmpty);
        expect(resolved, isFalse);
        expect(prepared, isFalse);
      });
    }
  }

  test('x64 executable sections need not have instruction word alignment', () {
    final allocator = RecordingAllocator(4096);
    addTearDown(allocator.dispose);
    final bytes = elfFixture(62);
    final data = ByteData.sublistView(bytes);
    data.setUint64(0x350, 0x1181, Endian.little);
    data.setUint64(0x358, 0x1181, Endian.little);
    data.setUint64(0x360, 5, Endian.little);
    final regions = <(int, int)>[];
    final library = ElfLoadedLibrary.load(
      bytes,
      allocator,
      (_) => nullptr,
      machine: 62,
      codePreparation: CallbackElfCodePreparation((code, length) {
        regions.add((code.address, length));
      }),
    );
    expect(regions.last, (library.lookup('local').address + 0x81, 5));
  });

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
            machine: machine,
            codePreparation: const UnmodifiedElfCodePreparation(),
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
    final library = ElfLoadedLibrary.load(
      bytes,
      allocator,
      (_) => nullptr,
      machine: machine,
      codePreparation: const UnmodifiedElfCodePreparation(),
    );
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
      () => ElfLoadedLibrary.load(
        bytes,
        allocator,
        (_) => nullptr,
        machine: machine,
        codePreparation: const UnmodifiedElfCodePreparation(),
      ),
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
        () => ElfLoadedLibrary.load(
          bytes,
          allocator,
          (_) => nullptr,
          machine: machine,
          codePreparation: const UnmodifiedElfCodePreparation(),
        ),
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
      () => ElfLoadedLibrary.load(
        bytes,
        allocator,
        (_) => nullptr,
        machine: machine,
        codePreparation: const UnmodifiedElfCodePreparation(),
      ),
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
        machine: machine,
        codePreparation: const UnmodifiedElfCodePreparation(),
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
        () => ElfLoadedLibrary.load(
          bytes,
          allocator,
          (_) => nullptr,
          machine: machine,
          codePreparation: const UnmodifiedElfCodePreparation(),
        ),
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
      () => ElfLoadedLibrary.load(
        bytes,
        allocator,
        (_) => nullptr,
        machine: machine,
        codePreparation: const UnmodifiedElfCodePreparation(),
      ),
      throwsUnsupportedError,
    );
    expect(allocator.allocated, isNull);
  });
}
