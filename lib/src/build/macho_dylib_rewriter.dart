import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/util/errors.dart';

/// Rewrites install names in 64-bit little-endian Mach-O dynamic libraries.
abstract final class MachODylibRewriter {
  static const _magic64 = 0xfeedfacf;
  static const _headerSize64 = 32;
  static const _loadDylib = 0x0c;
  static const _idDylib = 0x0d;
  static const _loadWeakDylib = 0x80000018;
  static const _reexportDylib = 0x8000001f;
  static const _loadUpwardDylib = 0x80000023;

  /// Rewrites [path] in place and leaves unrelated dependency paths unchanged.
  static Future<void> rewriteFile(
    String path, {
    required Set<String> producedDylibNames,
  }) async {
    final file = File(path);
    final bytes = await file.readAsBytes();
    final changed = rewriteBytes(
      bytes,
      dylibName: p.basename(path),
      producedDylibNames: producedDylibNames,
      source: path,
    );
    if (changed) await file.writeAsBytes(bytes, flush: true);
  }

  /// Rewrites load-command strings in [bytes]. Returns whether bytes changed.
  @visibleForTesting
  static bool rewriteBytes(
    Uint8List bytes, {
    required String dylibName,
    required Set<String> producedDylibNames,
    String source = 'Mach-O data',
  }) {
    Never invalid(String message) =>
        throw XcrossError('$source: invalid Mach-O: $message');

    if (bytes.length < _headerSize64) invalid('truncated 64-bit header');
    final data = ByteData.sublistView(bytes);
    if (data.getUint32(0, Endian.little) != _magic64) {
      invalid('expected 64-bit little-endian magic');
    }

    final commandCount = data.getUint32(16, Endian.little);
    final commandsSize = data.getUint32(20, Endian.little);
    final commandsEnd = _headerSize64 + commandsSize;
    if (commandsEnd > bytes.length) invalid('load commands exceed file bounds');

    var changed = false;
    var commandOffset = _headerSize64;
    for (var index = 0; index < commandCount; index++) {
      if (commandOffset + 8 > commandsEnd) {
        invalid('load command $index header exceeds bounds');
      }
      final command = data.getUint32(commandOffset, Endian.little);
      final commandSize = data.getUint32(commandOffset + 4, Endian.little);
      if (commandSize < 8 || commandOffset + commandSize > commandsEnd) {
        invalid('load command $index has invalid size $commandSize');
      }

      final isDependency =
          command == _loadDylib ||
          command == _loadWeakDylib ||
          command == _reexportDylib ||
          command == _loadUpwardDylib;
      if (command == _idDylib || isDependency) {
        if (commandSize < 24) {
          invalid('dylib command $index is shorter than 24 bytes');
        }
        final nameOffset = data.getUint32(commandOffset + 8, Endian.little);
        if (nameOffset < 24 || nameOffset >= commandSize) {
          invalid('dylib command $index has invalid name offset $nameOffset');
        }
        final nameStart = commandOffset + nameOffset;
        final commandEnd = commandOffset + commandSize;
        var nameEnd = nameStart;
        while (nameEnd < commandEnd && bytes[nameEnd] != 0) {
          nameEnd++;
        }
        if (nameEnd == commandEnd) {
          invalid('dylib command $index name is not null-terminated');
        }

        final oldName = utf8.decode(bytes.sublist(nameStart, nameEnd));
        final basename = oldName.substring(oldName.lastIndexOf('/') + 1);
        final replacement = command == _idDylib
            ? '@rpath/$dylibName'
            : producedDylibNames.contains(basename)
            ? '@rpath/$basename'
            : null;
        if (replacement != null && replacement != oldName) {
          final replacementBytes = utf8.encode(replacement);
          final oldLength = nameEnd - nameStart;
          if (replacementBytes.length > oldLength) {
            invalid('replacement "$replacement" is longer than "$oldName"');
          }
          bytes.fillRange(nameStart, nameEnd, 0);
          bytes.setRange(
            nameStart,
            nameStart + replacementBytes.length,
            replacementBytes,
          );
          changed = true;
        }
      }
      commandOffset += commandSize;
    }
    if (commandOffset != commandsEnd) {
      invalid('load command sizes do not match header');
    }
    return changed;
  }
}
