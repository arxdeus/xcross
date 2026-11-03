import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:xcross/src/shared/apple/mach_o.dart';
import 'package:xcross/src/shared/flutter/build/objc_fast_stub_rewriter.dart';
import 'package:xcross/src/shared/flutter/errors.dart';

/// Rewrites install names in 64-bit little-endian Mach-O dynamic libraries.
@internal
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

  /// Rewrites load-command strings in [bytes]. Returns whether bytes changed.
  static bool rewriteBytes(
    Uint8List bytes, {
    required String dylibName,
    required Set<String> producedDylibNames,
    String? installName,
    Map<String, String> producedInstallNames = const {},
    bool repairObjCFastStubs = false,
    bool replaceRelocatableId = false,
    String source = 'Mach-O data',
  }) {
    Never invalid(String message) => _invalid(source, message);
    var machO = MachOFile.parse(bytes, invalid: invalid);

    var changed = false;
    // A command that grows shifts the commands after it, so the file is
    // parsed again after each growth; rewritten names then compare equal.
    for (var grown = true; grown;) {
      grown = false;
      for (final command in machO.commands) {
        final isId = command.type == _idDylib;
        if (!isId && !_dependencyCommands.contains(command.type)) continue;
        final result = _rewriteInstallName(
          machO,
          command,
          isId: isId,
          dylibName: dylibName,
          installName: installName,
          producedDylibNames: producedDylibNames,
          producedInstallNames: producedInstallNames,
          replaceRelocatableId: replaceRelocatableId,
        );
        changed |= result.changed;
        if (result.grown) {
          grown = true;
          machO = MachOFile.parse(bytes, invalid: invalid);
          break;
        }
      }
    }
    if (repairObjCFastStubs &&
        machO.cpuType == MachOConstants.cpuTypeArm64 &&
        machO.fileType == MachOConstants.mhDylib) {
      changed |= ObjCFastStubRewriter.repair(machO);
    }

    return changed;
  }

  /// Rewrites the inline install-name string of one `dylib_command`.
  ///
  /// `LC_ID_DYLIB` always becomes `@rpath/<dylibName>`; a dependency is
  /// rewritten only when its basename names a dylib produced by this build.
  /// A longer name grows the command into the padding between the load
  /// commands and the first section (`-headerpad_max_install_names`).
  static ({bool changed, bool grown}) _rewriteInstallName(
    MachOFile file,
    MachOLoadCommand command, {
    required bool isId,
    required String dylibName,
    required String? installName,
    required Set<String> producedDylibNames,
    required Map<String, String> producedInstallNames,
    required bool replaceRelocatableId,
  }) {
    const unchanged = (changed: false, grown: false);
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
    if (isId && !replaceRelocatableId && oldName.startsWith('@rpath/')) {
      return unchanged;
    }
    final replacement = isId
        ? installName ?? '@rpath/$dylibName'
        : producedInstallNames[basename] ??
              (producedDylibNames.contains(basename)
                  ? '@rpath/$basename'
                  : null);

    if (replacement == null || replacement == oldName) return unchanged;

    final replacementBytes = utf8.encode(replacement);
    final capacity = commandEnd - nameStart;
    var end = commandEnd;
    if (replacementBytes.length >= capacity) {
      final size = (nameOffset + replacementBytes.length + 1 + 7) & ~7;
      _grow(file, command, size, replacement, oldName);
      end = command.offset + size;
    }
    file.bytes.fillRange(nameStart, end, 0);
    file.bytes.setRange(
      nameStart,
      nameStart + replacementBytes.length,
      replacementBytes,
    );
    return (changed: true, grown: end != commandEnd);
  }

  /// Grows [command] to [size] bytes, moving the load commands after it
  /// into the header padding.
  static void _grow(
    MachOFile file,
    MachOLoadCommand command,
    int size,
    String replacement,
    String oldName,
  ) {
    final commandsSize = file.data.getUint32(20, Endian.little);
    final commandsEnd = MachOConstants.headerSize64 + commandsSize;
    final delta = size - command.size;
    if (commandsEnd + delta > _firstContentOffset(file)) {
      file.invalid(
        'replacement "$replacement" does not fit "$oldName" and the header '
        'has no room to grow (link with -headerpad_max_install_names)',
      );
    }
    final commandEnd = command.offset + command.size;
    file.bytes.setRange(
      commandEnd + delta,
      commandsEnd + delta,
      Uint8List.fromList(file.bytes.sublist(commandEnd, commandsEnd)),
    );
    file.data
      ..setUint32(command.offset + 4, size, Endian.little)
      ..setUint32(20, commandsSize + delta, Endian.little);
  }

  /// File offset of the first section with file contents: load commands may
  /// grow up to it.
  static int _firstContentOffset(MachOFile file) {
    var first = file.bytes.length;
    final segments = file.commands.where(
      (command) => command.type == MachOConstants.lcSegment64,
    );
    for (final section in file.parseSections(segments)) {
      if (section.fileOffset > 0 &&
          section.size > 0 &&
          section.fileOffset < first) {
        first = section.fileOffset;
      }
    }
    return first;
  }

  static Never _invalid(String source, String message) =>
      throw FlutterBuildError('$source: invalid Mach-O: $message');
}
