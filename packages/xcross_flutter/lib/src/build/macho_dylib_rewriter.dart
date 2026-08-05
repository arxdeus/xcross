import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross_flutter/src/errors.dart';

/// Rewrites install names in 64-bit little-endian Mach-O dynamic libraries.
abstract final class MachODylibRewriter {
  static const _magic64 = 0xfeedfacf;

  /// `mach_header_64` is 32 bytes; load commands start right after it.
  static const _headerSize64 = 32;

  /// `LC_ID_DYLIB` — this library's own install name.
  static const _idDylib = 0x0d;

  /// Load commands carrying a dependency's install name. Each has the same
  /// `dylib_command` layout as `LC_ID_DYLIB`.
  static const _dependencyCommands = <int>{
    0x0c, // LC_LOAD_DYLIB
    0x8000_0018, // LC_LOAD_WEAK_DYLIB
    0x8000_001f, // LC_REEXPORT_DYLIB
    0x8000_0023, // LC_LOAD_UPWARD_DYLIB
  };

  /// Byte size of `dylib_command` up to (excluding) its inline name string:
  /// cmd, cmdsize, name offset, timestamp, current version, compat version.
  static const _dylibCommandHeaderSize = 24;

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
    if (bytes.length < _headerSize64) {
      _invalid(source, 'truncated 64-bit header');
    }
    final data = ByteData.sublistView(bytes);
    if (data.getUint32(0, Endian.little) != _magic64) {
      _invalid(source, 'expected 64-bit little-endian magic');
    }

    final commandCount = data.getUint32(16, Endian.little);
    final commandsSize = data.getUint32(20, Endian.little);
    final commandsEnd = _headerSize64 + commandsSize;
    if (commandsEnd > bytes.length) {
      _invalid(source, 'load commands exceed file bounds');
    }

    var changed = false;
    var commandOffset = _headerSize64;
    for (var index = 0; index < commandCount; index++) {
      if (commandOffset + 8 > commandsEnd) {
        _invalid(source, 'load command $index header exceeds bounds');
      }
      final command = data.getUint32(commandOffset, Endian.little);
      final commandSize = data.getUint32(commandOffset + 4, Endian.little);
      if (commandSize < 8 || commandOffset + commandSize > commandsEnd) {
        _invalid(source, 'load command $index has invalid size $commandSize');
      }

      final isId = command == _idDylib;
      if (isId || _dependencyCommands.contains(command)) {
        changed |= _rewriteInstallName(
          bytes,
          data,
          source: source,
          index: index,
          commandOffset: commandOffset,
          commandSize: commandSize,
          isId: isId,
          dylibName: dylibName,
          producedDylibNames: producedDylibNames,
        );
      }
      commandOffset += commandSize;
    }
    if (commandOffset != commandsEnd) {
      _invalid(source, 'load command sizes do not match header');
    }
    return changed;
  }

  /// Rewrites the inline install-name string of one `dylib_command`.
  ///
  /// `LC_ID_DYLIB` always becomes `@rpath/<dylibName>`; a dependency is
  /// rewritten to `@rpath/<basename>` only when we produced that dylib
  /// ourselves, so system and SDK dependencies stay untouched.
  ///
  /// The name lives inside the command's own bytes, so the replacement is
  /// written in place and can never grow: it must stay strictly shorter than
  /// the remaining command bytes to leave room for the NUL terminator. The
  /// slack the linker left as string-table padding is zero-filled first.
  static bool _rewriteInstallName(
    Uint8List bytes,
    ByteData data, {
    required String source,
    required int index,
    required int commandOffset,
    required int commandSize,
    required bool isId,
    required String dylibName,
    required Set<String> producedDylibNames,
  }) {
    if (commandSize < _dylibCommandHeaderSize) {
      _invalid(
        source,
        'dylib command $index is shorter than '
        '$_dylibCommandHeaderSize bytes',
      );
    }
    final nameOffset = data.getUint32(commandOffset + 8, Endian.little);
    if (nameOffset < _dylibCommandHeaderSize || nameOffset >= commandSize) {
      _invalid(
        source,
        'dylib command $index has invalid name offset '
        '$nameOffset',
      );
    }

    final nameStart = commandOffset + nameOffset;
    final commandEnd = commandOffset + commandSize;
    var nameEnd = nameStart;
    while (nameEnd < commandEnd && bytes[nameEnd] != 0) {
      nameEnd++;
    }
    if (nameEnd == commandEnd) {
      _invalid(source, 'dylib command $index name is not null-terminated');
    }

    final oldName = utf8.decode(bytes.sublist(nameStart, nameEnd));
    final basename = oldName.substring(oldName.lastIndexOf('/') + 1);
    final replacement = isId
        ? '@rpath/$dylibName'
        : producedDylibNames.contains(basename)
        ? '@rpath/$basename'
        : null;
    if (replacement == null || replacement == oldName) return false;

    final replacementBytes = utf8.encode(replacement);
    final capacity = commandEnd - nameStart;
    if (replacementBytes.length >= capacity) {
      _invalid(source, 'replacement "$replacement" does not fit "$oldName"');
    }
    bytes.fillRange(nameStart, commandEnd, 0);
    bytes.setRange(
      nameStart,
      nameStart + replacementBytes.length,
      replacementBytes,
    );
    return true;
  }

  static Never _invalid(String source, String message) =>
      throw FlutterBuildError('$source: invalid Mach-O: $message');
}
