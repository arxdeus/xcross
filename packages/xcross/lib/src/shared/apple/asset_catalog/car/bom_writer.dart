import 'dart:typed_data';

import 'package:meta/meta.dart';

/// Writes a `BOMStore` file: Apple's Bill of Materials container that
/// `Assets.car` is built on. All integers are big-endian.
///
/// The store is a list of numbered blocks plus a table of named variables
/// that point at blocks. Block 0 is always the null block.
@internal
final class BomWriter {
  final List<Uint8List> _blocks = [Uint8List(0)];
  final List<(String, int)> _variables = [];

  /// Adds a raw block and returns its index.
  int addBlock(Uint8List data) {
    _blocks.add(data);
    return _blocks.length - 1;
  }

  /// Names [blockIndex] as variable [name].
  void addVariable(String name, int blockIndex) =>
      _variables.add((name, blockIndex));

  /// Adds a single-leaf BOM tree holding [entries] (key bytes → value bytes)
  /// in the given order and returns the index of its `tree` block.
  int addTree(List<(Uint8List, Uint8List)> entries, {int blockSize = 4096}) {
    final pathsLength = 12 + entries.length * 8;
    var size = blockSize;
    while (size < pathsLength) {
      size *= 2;
    }
    final paths = Uint8List(size);
    final pathsData = ByteData.sublistView(paths)
      ..setUint16(0, 1) // isLeaf
      ..setUint16(2, entries.length)
      ..setUint32(4, 0) // forward
      ..setUint32(8, 0); // backward
    // Paths block is added before the entry blocks, but its pair table
    // needs their indices, so reserve it first and patch it in place.
    final pathsIndex = addBlock(paths);
    // The same value object (e.g. one icon bitmap used for iPhone and iPad)
    // is stored once and referenced by every key that maps to it.
    final shared = Map<Uint8List, int>.identity();
    for (final (i, (key, value)) in entries.indexed) {
      final keyIndex = addBlock(key);
      final valueIndex = shared[value] ??= addBlock(value);
      pathsData
        ..setUint32(12 + i * 8, valueIndex)
        ..setUint32(16 + i * 8, keyIndex);
    }
    final tree = Uint8List(21);
    ByteData.sublistView(tree)
      ..setUint32(0, 0x74726565) // 'tree'
      ..setUint32(4, 1)
      ..setUint32(8, pathsIndex)
      ..setUint32(12, size)
      ..setUint32(16, entries.length);
    return addBlock(tree);
  }

  Uint8List build() {
    final out = BytesBuilder(copy: false);
    const headerSize = 512;
    var offset = headerSize;
    final addresses = <(int, int)>[];
    final dataParts = <Uint8List>[];
    for (final block in _blocks) {
      if (block.isEmpty) {
        addresses.add((0, 0));
        continue;
      }
      addresses.add((offset, block.length));
      final padded = (block.length + 15) & ~15;
      final part = Uint8List(padded)..setRange(0, block.length, block);
      dataParts.add(part);
      offset += padded;
    }

    final varsBuilder = BytesBuilder()..add(_u32(_variables.length));
    for (final (name, index) in _variables) {
      final nameBytes = Uint8List.fromList(name.codeUnits);
      varsBuilder
        ..add(_u32(index))
        ..addByte(nameBytes.length)
        ..add(nameBytes);
    }
    final vars = varsBuilder.toBytes();
    final varsOffset = offset;
    offset += (vars.length + 15) & ~15;

    final index = BytesBuilder()..add(_u32(addresses.length));
    for (final (address, length) in addresses) {
      index
        ..add(_u32(address))
        ..add(_u32(length));
    }
    index.add(_u32(0)); // empty free list
    final indexBytes = index.toBytes();
    final indexOffset = offset;

    final header = Uint8List(headerSize);
    header.setRange(0, 8, 'BOMStore'.codeUnits);
    ByteData.sublistView(header)
      ..setUint32(8, 1)
      ..setUint32(12, addresses.where((a) => a.$2 != 0).length)
      ..setUint32(16, indexOffset)
      ..setUint32(20, indexBytes.length)
      ..setUint32(24, varsOffset)
      ..setUint32(28, vars.length);

    out.add(header);
    dataParts.forEach(out.add);
    out
      ..add(vars)
      ..add(Uint8List(((vars.length + 15) & ~15) - vars.length))
      ..add(indexBytes);
    return out.toBytes();
  }

  static Uint8List _u32(int value) =>
      Uint8List(4)..buffer.asByteData().setUint32(0, value);
}
