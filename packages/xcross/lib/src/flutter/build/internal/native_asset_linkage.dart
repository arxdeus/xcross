import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:xcross/src/apple/mach_o.dart';
import 'package:xcross/src/flutter/errors.dart';

// mach_header_64 flags.
const _headerFlagsOffset = 24;
const _twoLevelNamespace = 0x80;
const _forceFlatNamespace = 0x100;

// nlist_64 layout and n_type / n_desc bits.
const _nlistSize = 16;
const _nlistDescriptionOffset = 6;
const _libraryOrdinalShift = 8;
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

// Load commands carrying an export trie, with their offset/size fields.
const _dyldInfo = 0x22;
const _dyldInfoOnly = 0x80000022;
const _dyldInfoMinimumSize = 48;
const _dyldInfoExportOffset = 40;
const _exportsTrie = 0x80000033;
const _linkeditDataMinimumSize = 16;
const _linkeditDataOffset = 8;

// ULEB128 encoding.
const _ulebPayloadMask = 0x7f;
const _ulebContinuation = 0x80;
const _ulebMaximumShift = 63;

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

typedef _SymbolEntry = ({
  int index,
  MachOSymbol symbol,
  MachOSymbolTable table,
});

/// Every symbol of every `LC_SYMTAB`, read lazily in load-command order, or
/// null when the file has no symbol table.
Iterable<_SymbolEntry>? _symbolTableEntries(MachOFile file) {
  final hasSymbolTable = file.commands.any(
    (command) => command.type == MachOConstants.lcSymtab,
  );
  return hasSymbolTable ? _lazySymbolTableEntries(file) : null;
}

Iterable<_SymbolEntry> _lazySymbolTableEntries(MachOFile file) sync* {
  for (final command in file.commands) {
    if (command.type != MachOConstants.lcSymtab) continue;
    final table = file.parseSymbolTable(command);
    for (var index = 0; index < table.symbolCount; index++) {
      yield (index: index, symbol: table.symbolAt(index), table: table);
    }
  }
}

/// Undefined external symbols a plugin library expects dyld to resolve from
/// any loaded image: flat-namespace imports and two-level dynamic lookups.
Future<Set<String>> _unboundImports(String path) async {
  final file = await _readMachO(path);
  final flags = file.data.getUint32(_headerFlagsOffset, Endian.little);
  final twoLevel =
      (flags & _twoLevelNamespace) != 0 && (flags & _forceFlatNamespace) == 0;
  final entries = _symbolTableEntries(file);
  if (entries == null) {
    throw FlutterBuildError('Plugin library has no Mach-O symbol table: $path');
  }
  final imports = <String>{};
  for (final (:index, :symbol, :table) in entries) {
    if (!_isUndefinedPublicSymbol(symbol.type)) continue;
    final description = file.data.getUint16(
      table.symbolOffset + index * _nlistSize + _nlistDescriptionOffset,
      Endian.little,
    );
    // A weak import must not make its provider a required Runner dependency.
    if ((description & _weakReference) != 0) continue;
    if (twoLevel && !_isUnboundOrdinal(description >> _libraryOrdinalShift)) {
      continue;
    }
    imports.add(table.symbolName(index, symbol));
  }
  return imports;
}

bool _isUndefinedPublicSymbol(int type) =>
    (type & _stab) == 0 &&
    (type & _external) != 0 &&
    (type & _privateExternal) == 0 &&
    (type & _symbolType) == _undefined;

/// Two-level ordinals that do not name a specific dependent library.
bool _isUnboundOrdinal(int ordinal) =>
    ordinal == _dynamicLookupOrdinal || ordinal == _executableOrdinal;

/// Symbols a framework exports, preferring dyld's export trie.
Future<Set<String>> _publicExports(String path) async {
  final file = await _readMachO(path);
  for (final command in file.commands) {
    if (command.type == _exportsTrie) {
      if (command.size < _linkeditDataMinimumSize) {
        file.invalid('truncated exports trie command');
      }
      return _readExportTrieAt(file, command.offset + _linkeditDataOffset);
    }
  }
  for (final command in file.commands) {
    if (command.type == _dyldInfo || command.type == _dyldInfoOnly) {
      if (command.size < _dyldInfoMinimumSize) {
        file.invalid('truncated dyld info command');
      }
      return _readExportTrieAt(file, command.offset + _dyldInfoExportOffset);
    }
  }

  // Older Mach-O files without dyld export metadata use their public nlist.
  final entries = _symbolTableEntries(file);
  if (entries == null) {
    throw FlutterBuildError('Native framework has no export metadata: $path');
  }
  return {
    for (final (:index, :symbol, :table) in entries)
      if (_isDefinedPublicSymbol(symbol.type)) table.symbolName(index, symbol),
  };
}

bool _isDefinedPublicSymbol(int type) {
  if ((type & (_stab | _privateExternal)) != 0 || (type & _external) == 0) {
    return false;
  }
  final kind = type & _symbolType;
  return kind == _section || kind == _absolute || kind == _indirect;
}

/// Read the export trie whose `(offset, size)` uint32 pair starts at
/// [fieldOffset] inside a load command.
Set<String> _readExportTrieAt(MachOFile file, int fieldOffset) =>
    _ExportTrieReader(
      file,
      file.data.getUint32(fieldOffset, Endian.little),
      file.data.getUint32(fieldOffset + 4, Endian.little),
    ).exports();

/// Walks a dyld export trie, collecting every terminal's symbol name.
final class _ExportTrieReader {
  _ExportTrieReader(this._file, this._offset, this._size);

  final MachOFile _file;
  final int _offset;
  final int _size;
  final _exports = <String>{};
  final _activeNodes = <int>{};

  int get _end => _offset + _size;

  Set<String> exports() {
    if (_size == 0) return const {};
    if (!MachOFile.rangeFits(_offset, _size, _file.bytes.length)) {
      _file.invalid('exports trie exceeds file bounds');
    }
    _visit(0, '');
    return _exports;
  }

  ({int value, int next}) _readUleb(int start) {
    var cursor = start;
    var value = 0;
    var shift = 0;
    while (cursor < _end && shift <= _ulebMaximumShift) {
      final byte = _file.bytes[cursor++];
      value |= (byte & _ulebPayloadMask) << shift;
      if (byte & _ulebContinuation == 0) {
        return (value: value, next: cursor);
      }
      shift += 7;
    }
    _file.invalid('invalid exports trie ULEB128');
  }

  void _visit(int node, String prefix) {
    // Rejecting a node already on the path guards against cyclic tries.
    if (node >= _size || !_activeNodes.add(node)) {
      _file.invalid('invalid exports trie node');
    }
    var cursor = _offset + node;
    final terminal = _readUleb(cursor);
    final terminalSize = terminal.value;
    cursor = terminal.next;
    if (terminalSize > _end - cursor) {
      _file.invalid('exports trie terminal exceeds bounds');
    }
    if (terminalSize > 0) _exports.add(prefix);
    cursor += terminalSize;
    if (cursor >= _end) _file.invalid('exports trie child count missing');
    final children = _file.bytes[cursor++];
    for (var child = 0; child < children; child++) {
      final start = cursor;
      while (cursor < _end && _file.bytes[cursor] != 0) {
        cursor++;
      }
      if (cursor == _end) _file.invalid('unterminated exports trie edge');
      final edge = utf8.decode(_file.bytes.sublist(start, cursor));
      cursor++;
      final target = _readUleb(cursor);
      cursor = target.next;
      _visit(target.value, '$prefix$edge');
    }
    _activeNodes.remove(node);
  }
}
