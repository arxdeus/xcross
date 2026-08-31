import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/apple/mach_o.dart';

import 'package:xcross/src/flutter/errors.dart';

/// Rewrites install names in 64-bit little-endian Mach-O dynamic libraries.
abstract final class MachODylibRewriter {
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

  /// Byte size of `dylib_command` up to (excluding) its inline name string.
  static const _dylibCommandHeaderSize = 24;

  /// Rewrites [path] in place and leaves unrelated dependency paths unchanged.
  static Future<void> rewriteFile(
    String path, {
    required Set<String> producedDylibNames,
    String? installName,
    Map<String, String> producedInstallNames = const {},
  }) async {
    final file = File(path);
    final bytes = await file.readAsBytes();
    final changed = rewriteBytes(
      bytes,
      dylibName: p.basename(path),
      producedDylibNames: producedDylibNames,
      installName: installName,
      producedInstallNames: producedInstallNames,
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
    String? installName,
    Map<String, String> producedInstallNames = const {},
    String source = 'Mach-O data',
  }) {
    Never invalid(String message) => _invalid(source, message);
    final machO = MachOFile.parse(bytes, invalid: invalid);

    var changed = false;
    for (final command in machO.commands) {
      final isId = command.type == _idDylib;
      if (isId || _dependencyCommands.contains(command.type)) {
        changed |= _rewriteInstallName(
          machO,
          command,
          isId: isId,
          dylibName: dylibName,
          installName: installName,
          producedDylibNames: producedDylibNames,
          producedInstallNames: producedInstallNames,
        );
      }
    }

    return changed;
  }

  /// Rewrites the inline install-name string of one `dylib_command`.
  ///
  /// `LC_ID_DYLIB` always becomes `@rpath/<dylibName>`; a dependency is
  /// rewritten only when its basename names a dylib produced by this build.
  static bool _rewriteInstallName(
    MachOFile file,
    MachOLoadCommand command, {
    required bool isId,
    required String dylibName,
    required String? installName,
    required Set<String> producedDylibNames,
    required Map<String, String> producedInstallNames,
  }) {
    if (command.size < _dylibCommandHeaderSize) {
      file.invalid(
        'dylib command ${command.index} is shorter than '
        '$_dylibCommandHeaderSize bytes',
      );
    }
    final nameOffset = file.data.getUint32(command.offset + 8, Endian.little);
    if (nameOffset < _dylibCommandHeaderSize || nameOffset >= command.size) {
      file.invalid(
        'dylib command ${command.index} has invalid name offset $nameOffset',
      );
    }

    final nameStart = command.offset + nameOffset;
    final commandEnd = command.offset + command.size;
    final oldName = file.nullTerminatedString(
      nameStart,
      commandEnd,
      'dylib command ${command.index} name is not null-terminated',
    );
    final basename = oldName.substring(oldName.lastIndexOf('/') + 1);
    if (isId && oldName.startsWith('@rpath/')) return false;
    final replacement = isId
        ? installName ?? '@rpath/$dylibName'
        : producedInstallNames[basename] ??
              (producedDylibNames.contains(basename)
                  ? '@rpath/$basename'
                  : null);

    if (replacement == null || replacement == oldName) return false;

    final replacementBytes = utf8.encode(replacement);
    final capacity = commandEnd - nameStart;
    if (replacementBytes.length >= capacity) {
      file.invalid('replacement "$replacement" does not fit "$oldName"');
    }
    file.bytes.fillRange(nameStart, commandEnd, 0);
    file.bytes.setRange(
      nameStart,
      nameStart + replacementBytes.length,
      replacementBytes,
    );
    return true;
  }

  static Never _invalid(String source, String message) =>
      throw FlutterBuildError('$source: invalid Mach-O: $message');
}
