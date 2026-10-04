@TestOn('windows')
library;

import 'dart:ffi';

import 'package:apple_developer_kit/src/host/shared/adi/loader/internal/sysv_abi_bridge.dart';
import 'package:apple_developer_kit/src/host/windows/adi/loader/internal/memory_allocator_windows.dart';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

const _return = 0xd65f03c0;
const _readX18 = [0xaa1203e0, _return];
const _callWithShadowStack = [
  0xf800865e,
  0xaa0003f0,
  0xaa0103e0,
  0xd63f0200,
  0xf85f8e5e,
  _return,
];

Pointer<Void> _code(List<int> instructions, {int? patched}) {
  final allocator = WindowsMemoryAllocator();
  final block = allocator.alloc(instructions.length * 4);
  addTearDown(() => allocator.free(block));
  block.pointer
      .cast<Uint32>()
      .asTypedList(instructions.length)
      .setAll(0, instructions);
  if (patched != null) {
    expect(
      provisionWindowsArm64PrepareCode(block.pointer.cast(), block.length),
      patched,
    );
  }
  allocator.protect(
    block,
    offset: 0,
    length: block.length,
    readable: true,
    writable: false,
    executable: true,
  );
  allocator.flushInstructionCache(block);
  return block.pointer.cast();
}

int Function() _integerProbe(Pointer<Void> code) =>
    code.cast<NativeFunction<Uint64 Function()>>().asFunction<int Function()>();

void main() {
  if (Abi.current() != Abi.windowsArm64) {
    test('requires native Windows ARM64', () {}, skip: true);
    return;
  }

  test('rejects invalid wrapper pointers and argument counts', () {
    for (final wrap in [provisionSysvWrapImport, provisionSysvWrapExport]) {
      expect(wrap(nullptr, 0), nullptr);
      final code = _code([_return]);
      expect(wrap(code, -1), nullptr);
      expect(wrap(code, 9), nullptr);
    }
  });

  test('preserves all eight fixed integer argument registers', () {
    final target = _code([
      0x8b010400,
      0x8b020800,
      0x8b030c00,
      0x8b041000,
      0x8b051400,
      0x8b061800,
      0x8b071c00,
      _return,
    ]);
    final call = provisionSysvWrapImport(target, 8)
        .cast<
          NativeFunction<
            Uint64 Function(
              Uint64,
              Uint64,
              Uint64,
              Uint64,
              Uint64,
              Uint64,
              Uint64,
              Uint64,
            )
          >
        >()
        .asFunction<int Function(int, int, int, int, int, int, int, int)>();
    expect(call(1, 2, 3, 4, 5, 6, 7, 8), 1793);
  });

  test(
    'switches x18 to bounded guest storage and restores the Windows TEB',
    () {
      final target = _code(_readX18);
      final host = _integerProbe(target);
      final guest = _integerProbe(provisionSysvWrapImport(target, 0));
      final teb = host();
      final shadow = guest();
      expect(shadow, isNot(teb));
      expect(shadow & 0xffff, 8192);
      expect(host(), teb);
      expect(guest(), shadow);
      final context = Pointer<Uint64>.fromAddress(shadow & ~0xffff);
      expect(context[0], teb);
      expect(context[1], shadow);
      expect(context[7], isNot(0));
      final query = DynamicLibrary.process()
          .lookupFunction<
            Size Function(Pointer<Void>, Pointer<Void>, Size),
            int Function(Pointer<Void>, Pointer<Void>, int)
          >('VirtualQuery');
      using((arena) {
        final info = arena<Uint8>(48);
        for (final offset in [4096, 61440]) {
          expect(
            query((context.cast<Uint8>() + offset).cast(), info.cast(), 48),
            48,
          );
          expect((info + 32).cast<Uint32>().value, 0x2000);
        }
      });
    },
  );

  test('adapts TPIDR reads without modifying Windows TPIDR_EL0', () {
    final osTls = _integerProbe(_code([0xd53bd040, _return]));
    final original = osTls();
    final target = _code([0xd53bd040, 0xf9401400, _return], patched: 1);
    final guard = _integerProbe(provisionSysvWrapImport(target, 0));
    final first = guard();
    expect(first, isNot(0));
    expect(guard(), first);
    expect(osTls(), original);
  });

  test('preserves floating arguments and a returned double', () {
    final target = _code([0x1e612800, _return]);
    final call = provisionSysvWrapImport(target, 2)
        .cast<NativeFunction<Double Function(Double, Double)>>()
        .asFunction<double Function(double, double)>();
    expect(call(1.25, 7.5), 8.75);
  });

  test(
    'nested callbacks restore TEB, shadow cursor, TLS and integer results',
    () {
      final read = _code(_readX18);
      final host = _integerProbe(read);
      final guest = _integerProbe(provisionSysvWrapImport(read, 0));
      final teb = host();
      final shadow = guest();
      final guard = _integerProbe(
        provisionSysvWrapImport(
          _code([0xd53bd040, 0xf9401400, _return], patched: 1),
          0,
        ),
      );
      final cookie = guard();
      final callback = NativeCallable<Uint64 Function(Uint64)>.isolateLocal((
        int value,
      ) {
        expect(host(), teb);
        expect(guest(), shadow + 8);
        expect(guard(), cookie);
        expect(host(), teb);
        return value + 17;
      }, exceptionalReturn: 0);
      addTearDown(callback.close);
      final exported = provisionSysvWrapExport(
        callback.nativeFunction.cast(),
        1,
      );
      final call = provisionSysvWrapImport(_code(_callWithShadowStack), 2)
          .cast<NativeFunction<Uint64 Function(Pointer<Void>, Uint64)>>()
          .asFunction<int Function(Pointer<Void>, int)>();
      expect(call(exported, 100), 117);
      expect(host(), teb);
      expect(guest(), shadow);
      expect(guard(), cookie);
    },
  );

  test(
    'host callback double return survives the export and import epilogues',
    () {
      final callback = NativeCallable<Double Function(Uint64)>.isolateLocal(
        (int value) => value / 4,
        exceptionalReturn: -1.0,
      );
      addTearDown(callback.close);
      final exported = provisionSysvWrapExport(
        callback.nativeFunction.cast(),
        1,
      );
      final call = provisionSysvWrapImport(_code(_callWithShadowStack), 2)
          .cast<NativeFunction<Double Function(Pointer<Void>, Uint64)>>()
          .asFunction<double Function(Pointer<Void>, int)>();
      expect(call(exported, 50), 12.5);
    },
  );

  test(
    'preparation rejects unsafe reads and writes without partial patches',
    () {
      expect(provisionWindowsArm64PrepareCode(nullptr, 0), -1);
      final allocator = WindowsMemoryAllocator();
      final block = allocator.alloc(16);
      addTearDown(() => allocator.free(block));
      final words = block.pointer.cast<Uint32>();
      for (final rejected in [0xd53bd052, 0xd53bd05f, 0xd51bd040]) {
        words[0] = 0xd53bd040;
        words[1] = rejected;
        expect(provisionWindowsArm64PrepareCode(block.pointer.cast(), 8), -1);
        expect(words[0], 0xd53bd040);
        expect(words[1], rejected);
      }
      expect(provisionWindowsArm64PrepareCode(block.pointer.cast(), 3), -1);
      expect(
        provisionWindowsArm64PrepareCode((block.pointer + 1).cast(), 4),
        -1,
      );
      expect(
        provisionWindowsArm64PrepareCode(
          block.pointer.cast(),
          64 * 1024 * 1024 + 4,
        ),
        -1,
      );
      words[0] = _return;
      expect(provisionWindowsArm64PrepareCode(block.pointer.cast(), 4), 0);
      expect(words[0], _return);
    },
  );
}
