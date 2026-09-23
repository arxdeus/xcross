import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:xcross/src/apple/mach_o.dart';
import 'package:xcross/src/flutter/errors.dart';

const _twoLevelNamespace = 0x80;
const _forceFlatNamespace = 0x100;
const _dynamicLookupOrdinal = 0xfe;
const _executableOrdinal = 0xff;
const _privateExternal = 0x10;
const _weakReference = 0x40;
const _external = 0x01;
const _symbolType = 0x0e;
const _stab = 0xe0;
const _undefined = 0x00;
const _absolute = 0x02;
const _indirect = 0x0a;
const _section = 0x0e;
const _dyldInfo = 0x22;
const _dyldInfoOnly = 0x80000022;
const _exportsTrie = 0x80000033;

/// Eager-load only native frameworks that satisfy unbound SwiftPM plugin
/// imports. Other frameworks stay embedded for Flutter's manifest-driven
/// `dlopen` path and cannot change Runner startup behavior.
Future<List<String>> nativeFrameworksRequiredByPlugins(
  Iterable<String> frameworks,
  Iterable<String> pluginLibraries,
) async {
  final imports = <String>{};
  for (final library in pluginLibraries) {
    imports.addAll(await _unboundImports(library));
  }
  if (imports.isEmpty) return const [];

  final required = <String>[];
  for (final framework in frameworks) {
    final binary = p.join(framework, p.basenameWithoutExtension(framework));
    final exports = await _publicExports(binary);
    if (exports.any(imports.contains)) required.add(framework);
  }
  return required;
}

Future<MachOFile> _readMachO(String path) async => MachOFile.parse(
  await File(path).readAsBytes(),
  invalid: (message) =>
      throw FlutterBuildError('Invalid Mach-O $path: $message'),
);

Future<Set<String>> _unboundImports(String path) async {
  final file = await _readMachO(path);
  final flags = file.data.getUint32(24, Endian.little);
  final twoLevel =
      (flags & _twoLevelNamespace) != 0 && (flags & _forceFlatNamespace) == 0;
  final imports = <String>{};
  var foundTable = false;
  for (final command in file.commands) {
    if (command.type != MachOConstants.lcSymtab) continue;
    foundTable = true;
    final table = file.parseSymbolTable(command);
    for (var index = 0; index < table.symbolCount; index++) {
      final symbol = table.symbolAt(index);
      if ((symbol.type & _stab) != 0 ||
          (symbol.type & _external) == 0 ||
          (symbol.type & _privateExternal) != 0 ||
          (symbol.type & _symbolType) != _undefined) {
        continue;
      }
      final description = file.data.getUint16(
        table.symbolOffset + index * 16 + 6,
        Endian.little,
      );
      // A weak import must not make its provider a required Runner dependency.
      if ((description & _weakReference) != 0) continue;
      final ordinal = description >> 8;
      if (twoLevel &&
          ordinal != _dynamicLookupOrdinal &&
          ordinal != _executableOrdinal) {
        continue;
      }
      imports.add(table.symbolName(index, symbol));
    }
  }
  if (!foundTable) {
    throw FlutterBuildError('Plugin library has no Mach-O symbol table: $path');
  }
  return imports;
}

Future<Set<String>> _publicExports(String path) async {
  final file = await _readMachO(path);
  for (final command in file.commands) {
    if (command.type == _exportsTrie) {
      if (command.size < 16) file.invalid('truncated exports trie command');
      return _readExportTrie(
        file,
        file.data.getUint32(command.offset + 8, Endian.little),
        file.data.getUint32(command.offset + 12, Endian.little),
      );
    }
  }
  for (final command in file.commands) {
    if (command.type == _dyldInfo || command.type == _dyldInfoOnly) {
      if (command.size < 48) file.invalid('truncated dyld info command');
      return _readExportTrie(
        file,
        file.data.getUint32(command.offset + 40, Endian.little),
        file.data.getUint32(command.offset + 44, Endian.little),
      );
    }
  }

  // Older Mach-O files without dyld export metadata use their public nlist.
  final exports = <String>{};
  var foundTable = false;
  for (final command in file.commands) {
    if (command.type != MachOConstants.lcSymtab) continue;
    foundTable = true;
    final table = file.parseSymbolTable(command);
    for (var index = 0; index < table.symbolCount; index++) {
      final symbol = table.symbolAt(index);
      if ((symbol.type & (_stab | _privateExternal)) != 0 ||
          (symbol.type & _external) == 0) {
        continue;
      }
      final kind = symbol.type & _symbolType;
      if (kind == _section || kind == _absolute || kind == _indirect) {
        exports.add(table.symbolName(index, symbol));
      }
    }
  }
  if (!foundTable) {
    throw FlutterBuildError('Native framework has no export metadata: $path');
  }
  return exports;
}

Set<String> _readExportTrie(MachOFile file, int offset, int size) {
  if (size == 0) return const {};
  if (!MachOFile.rangeFits(offset, size, file.bytes.length)) {
    file.invalid('exports trie exceeds file bounds');
  }
  final end = offset + size;
  final exports = <String>{};
  final active = <int>{};

  ({int value, int next}) readUleb(int start) {
    var cursor = start;
    var value = 0;
    var shift = 0;
    while (cursor < end && shift <= 63) {
      final byte = file.bytes[cursor++];
      value |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) {
        return (value: value, next: cursor);
      }
      shift += 7;
    }
    file.invalid('invalid exports trie ULEB128');
  }

  void visit(int node, String prefix) {
    if (node >= size || !active.add(node)) {
      file.invalid('invalid exports trie node');
    }
    var cursor = offset + node;
    final terminal = readUleb(cursor);
    final terminalSize = terminal.value;
    cursor = terminal.next;
    if (terminalSize > end - cursor) {
      file.invalid('exports trie terminal exceeds bounds');
    }
    if (terminalSize > 0) exports.add(prefix);
    cursor += terminalSize;
    if (cursor >= end) file.invalid('exports trie child count missing');
    final children = file.bytes[cursor++];
    for (var child = 0; child < children; child++) {
      final start = cursor;
      while (cursor < end && file.bytes[cursor] != 0) {
        cursor++;
      }
      if (cursor == end) file.invalid('unterminated exports trie edge');
      final edge = utf8.decode(file.bytes.sublist(start, cursor));
      cursor++;
      final target = readUleb(cursor);
      cursor = target.next;
      visit(target.value, '$prefix$edge');
    }
    active.remove(node);
  }

  visit(0, '');
  return exports;
}
