import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:xcross/src/shared/flutter/build/swiftpm_binary_target.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';

@internal
final class SwiftPmArtifactArchiveInspector {
  const SwiftPmArtifactArchiveInspector({
    required this.policy,
    required this.fileSystem,
    required int maxEntries,
    required int maxExpandedBytes,
  }) : _maxEntries = maxEntries,
       _maxExpandedBytes = maxExpandedBytes;
  final FlutterTargetBuildPolicy policy;
  final SwiftPmArtifactFileSystem fileSystem;
  final int _maxEntries;
  final int _maxExpandedBytes;
  Archive decode(Uint8List bytes) {
    try {
      _rejectRawDuplicateEntries(bytes);
      return ZipDecoder().decodeBytes(bytes);
    } on FlutterBuildError {
      rethrow;
    } on Object {
      throw FlutterBuildError('SwiftPM binary artifact is not a valid ZIP');
    }
  }

  static void _rejectRawDuplicateEntries(Uint8List bytes) {
    final eocdStart = bytes.length - 22;
    final eocdLimit = bytes.length > 65557 ? bytes.length - 65557 : 0;
    var eocd = -1;
    for (var offset = eocdStart; offset >= eocdLimit; offset--) {
      if (_uint32(bytes, offset) == 0x06054b50) {
        eocd = offset;
        break;
      }
    }
    if (eocd < 0 || eocd + 22 + _uint16(bytes, eocd + 20) != bytes.length) {
      throw FlutterBuildError('SwiftPM binary artifact is not a valid ZIP');
    }
    final count = _uint16(bytes, eocd + 10);
    final centralSize = _uint32(bytes, eocd + 12);
    final centralOffset = _uint32(bytes, eocd + 16);
    if (count == 0xffff ||
        centralSize == 0xffffffff ||
        centralOffset == 0xffffffff ||
        centralOffset + centralSize != eocd) {
      throw FlutterBuildError(
        'SwiftPM binary artifact uses unsupported ZIP metadata',
      );
    }

    final names = <String>{};
    var offset = centralOffset;
    for (var index = 0; index < count; index++) {
      if (offset + 46 > eocd || _uint32(bytes, offset) != 0x02014b50) {
        throw FlutterBuildError('SwiftPM binary artifact is not a valid ZIP');
      }
      final nameLength = _uint16(bytes, offset + 28);
      final extraLength = _uint16(bytes, offset + 30);
      final commentLength = _uint16(bytes, offset + 32);
      final end = offset + 46 + nameLength + extraLength + commentLength;
      if (end > eocd) {
        throw FlutterBuildError('SwiftPM binary artifact is not a valid ZIP');
      }
      final name = utf8.decode(
        bytes.sublist(offset + 46, offset + 46 + nameLength),
      );
      if (!names.add(name)) {
        throw FlutterBuildError(
          'SwiftPM binary artifact has duplicate ZIP path: $name',
        );
      }
      offset = end;
    }
    if (offset != eocd) {
      throw FlutterBuildError('SwiftPM binary artifact is not a valid ZIP');
    }
  }

  static int _uint16(List<int> bytes, int offset) =>
      bytes[offset] | (bytes[offset + 1] << 8);

  static int _uint32(List<int> bytes, int offset) =>
      _uint16(bytes, offset) | (_uint16(bytes, offset + 2) << 16);

  InspectedXcFrameworkArchive inspect(
    Archive archive,
    SwiftPmRemoteBinaryTarget target,
  ) {
    if (archive.files.length > _maxEntries) {
      throw FlutterBuildError(
        'SwiftPM binary artifact exceeds ZIP entry limit',
      );
    }

    var expandedBytes = 0;
    final names = <String>{};
    final foldedNames = <String, String>{};
    final entries = <ValidatedArchiveEntry>[];
    for (final entry in archive.files) {
      expandedBytes += entry.size;
      if (expandedBytes > _maxExpandedBytes) {
        throw FlutterBuildError(
          'SwiftPM binary artifact exceeds ZIP expanded byte limit',
        );
      }
      final name = _safeArchiveName(entry.name);
      if (!names.add(name)) {
        throw FlutterBuildError(
          'SwiftPM binary artifact has duplicate ZIP path: $name',
        );
      }
      final folded = name.toLowerCase();
      final foldedWinner = foldedNames[folded];
      if (foldedWinner != null && foldedWinner != name) {
        throw FlutterBuildError(
          'SwiftPM binary artifact has case-folded ZIP path collision: '
          '$foldedWinner and $name',
        );
      }
      foldedNames[folded] = name;
      entries.add(ValidatedArchiveEntry(entry, name));
    }

    final plistName = '${target.name}.xcframework/Info.plist';
    final plistEntries = entries.where((entry) => entry.name == plistName);
    if (plistEntries.length != 1 ||
        !plistEntries.single.file.isFile ||
        plistEntries.single.file.isSymbolicLink) {
      throw FlutterBuildError(
        'SwiftPM binary artifact must contain exactly one root plist for '
        '${target.name}.xcframework',
      );
    }
    final plistBytes = _materialize(
      plistEntries.single.file,
      remainingBytes: _maxExpandedBytes,
    );
    final plist = _decodePlist(plistBytes);
    final materializedBytes = plistBytes.length;
    final librariesValue = plist['AvailableLibraries'];
    if (librariesValue is! List) {
      throw FlutterBuildError(
        'SwiftPM XCFramework AvailableLibraries must be an array',
      );
    }
    final libraries = <XcFrameworkLibrary>[];
    for (final value in librariesValue) {
      libraries.add(_parseLibrary(value));
    }
    final eligible = libraries
        .where(
          (library) =>
              library.platform == 'ios' &&
              policy.matchesLibraryVariant(library.variant) &&
              library.architectures.contains('arm64'),
        )
        .toList();
    if (eligible.length != 1) {
      throw FlutterBuildError(
        'SwiftPM XCFramework must contain exactly one eligible arm64 iOS '
        '${policy.target.buildPlatform.platformName} library; found ${eligible.length}',
      );
    }
    final library = eligible.single;
    final selectedPrefix = '${target.name}.xcframework/${library.identifier}/';
    if (entries.any(
      (entry) =>
          entry.name.startsWith(selectedPrefix) && entry.file.isSymbolicLink,
    )) {
      throw FlutterBuildError(
        'Unsupported SwiftPM binary artifact: selected device slice requires '
        'symlinks',
      );
    }
    return InspectedXcFrameworkArchive(
      entries: entries,
      plist: plist,
      library: library,
      artifactDirectoryName: '${target.name}.xcframework',
      selectedPrefix: selectedPrefix,
      materializedBytes: materializedBytes,
    );
  }

  Future<void> extractSelected(
    InspectedXcFrameworkArchive inspected,
    Directory artifact,
  ) async {
    final reducedPlist = <Object?, Object?>{
      ...inspected.plist,
      'AvailableLibraries': [inspected.library.raw],
    };
    await fileSystem
        .file(p.join(artifact.path, 'Info.plist'))
        .writeAsString(
          PropertyListSerialization.stringWithPropertyList(reducedPlist),
          flush: true,
        );
    var materializedBytes = inspected.materializedBytes;
    for (final entry in inspected.entries) {
      if (!entry.name.startsWith(inspected.selectedPrefix)) continue;
      final relative = entry.name.substring(
        inspected.artifactDirectoryName.length + 1,
      );
      final destination = p.joinAll([artifact.path, ...p.url.split(relative)]);
      if (entry.file.isDirectory) {
        await fileSystem.directory(destination).create(recursive: true);
      } else {
        await fileSystem
            .directory(p.dirname(destination))
            .create(recursive: true);
        final bytes = _materialize(
          entry.file,
          remainingBytes: _maxExpandedBytes - materializedBytes,
        );
        materializedBytes += bytes.length;
        await fileSystem.file(destination).writeAsBytes(bytes, flush: true);
      }
    }
  }

  void validateDeclaredPaths(XcFrameworkLibrary library, Directory artifact) {
    for (final declared in {
      'LibraryPath': library.libraryPath,
      if (library.headersPath != null) 'HeadersPath': library.headersPath!,
      if (library.debugSymbolsPath != null)
        'DebugSymbolsPath': library.debugSymbolsPath!,
    }.entries) {
      final relative = '${library.identifier}/${declared.value}';
      final path = p.joinAll([artifact.path, ...p.url.split(relative)]);
      if (fileSystem.typeSync(path, followLinks: false) ==
          FileSystemEntityType.notFound) {
        throw FlutterBuildError(
          'SwiftPM XCFramework declared ${declared.key} does not exist: '
          '${declared.value}',
        );
      }
    }
  }

  static Uint8List _materialize(
    ArchiveFile entry, {
    required int remainingBytes,
  }) {
    try {
      final bytes = entry.content;
      if (bytes.length > remainingBytes) {
        throw FlutterBuildError(
          'SwiftPM binary artifact exceeds ZIP expanded byte limit',
        );
      }
      return bytes;
    } on FlutterBuildError {
      rethrow;
    } on Object {
      throw FlutterBuildError(
        'SwiftPM binary artifact content could not be decompressed',
      );
    }
  }

  static Map<Object?, Object?> _decodePlist(Uint8List bytes) {
    final Object? value;
    try {
      value = PropertyListSerialization.propertyListWithString(
        utf8.decode(bytes),
      );
    } on Object {
      throw FlutterBuildError('SwiftPM XCFramework Info.plist is malformed');
    }
    if (value is! Map) {
      throw FlutterBuildError(
        'SwiftPM XCFramework Info.plist root must be a dictionary',
      );
    }
    return Map<Object?, Object?>.from(value);
  }

  static XcFrameworkLibrary _parseLibrary(Object? value) {
    if (value is! Map) {
      throw FlutterBuildError(
        'SwiftPM XCFramework library metadata must be a dictionary',
      );
    }
    final raw = Map<Object?, Object?>.from(value);
    final identifier = _requiredString(raw, 'LibraryIdentifier');
    final libraryPath = _requiredRelativePath(raw, 'LibraryPath');
    final platform = _requiredString(raw, 'SupportedPlatform');
    final variant = raw['SupportedPlatformVariant'];
    if (variant != null && variant is! String) {
      throw FlutterBuildError(
        'SwiftPM XCFramework SupportedPlatformVariant must be a string',
      );
    }
    final architecturesValue = raw['SupportedArchitectures'];
    if (architecturesValue is! List ||
        architecturesValue.any((value) => value is! String)) {
      throw FlutterBuildError(
        'SwiftPM XCFramework SupportedArchitectures must be a string array',
      );
    }
    return XcFrameworkLibrary(
      raw: raw,
      identifier: _safeRelativePath(identifier, 'LibraryIdentifier'),
      libraryPath: libraryPath,
      headersPath: _optionalRelativePath(raw, 'HeadersPath'),
      debugSymbolsPath: _optionalRelativePath(raw, 'DebugSymbolsPath'),
      platform: platform,
      variant: variant as String?,
      architectures: architecturesValue.cast<String>(),
    );
  }

  static String _requiredString(Map<Object?, Object?> map, String key) {
    final value = map[key];
    if (value is! String || value.isEmpty) {
      throw FlutterBuildError('SwiftPM XCFramework $key must be a string');
    }
    return value;
  }

  static String _requiredRelativePath(Map<Object?, Object?> map, String key) =>
      _safeRelativePath(_requiredString(map, key), key);

  static String? _optionalRelativePath(Map<Object?, Object?> map, String key) {
    final value = map[key];
    if (value == null) return null;
    if (value is! String || value.isEmpty) {
      throw FlutterBuildError('SwiftPM XCFramework $key must be a string');
    }
    return _safeRelativePath(value, key);
  }

  static String _safeRelativePath(String value, String label) {
    if (value.contains(r'\') || p.url.isAbsolute(value)) {
      throw FlutterBuildError('SwiftPM XCFramework $label is unsafe');
    }
    for (final component in p.url.split(value)) {
      if (!_isWindowsSafeComponent(component)) {
        throw FlutterBuildError('SwiftPM XCFramework $label is unsafe');
      }
    }
    if (RegExp('^[A-Za-z]:').hasMatch(value)) {
      throw FlutterBuildError('SwiftPM XCFramework $label is unsafe');
    }
    final normalized = p.url.normalize(value);
    if (normalized == '.' ||
        normalized == '..' ||
        normalized.startsWith('../') ||
        normalized != value) {
      throw FlutterBuildError('SwiftPM XCFramework $label is unsafe');
    }
    return normalized;
  }

  static String _safeArchiveName(String value) {
    if (value.isEmpty || value.contains(r'\') || value.startsWith('/')) {
      throw FlutterBuildError('SwiftPM binary artifact has unsafe ZIP path');
    }
    final withoutTrailingSlash = value.endsWith('/')
        ? value.substring(0, value.length - 1)
        : value;
    for (final component in p.url.split(withoutTrailingSlash)) {
      if (!_isWindowsSafeComponent(component)) {
        throw FlutterBuildError('SwiftPM binary artifact has unsafe ZIP path');
      }
    }
    if (RegExp('^[A-Za-z]:').hasMatch(value)) {
      throw FlutterBuildError('SwiftPM binary artifact has unsafe ZIP path');
    }
    final normalized = p.url.normalize(withoutTrailingSlash);
    if (normalized == '.' ||
        normalized == '..' ||
        normalized.startsWith('../') ||
        normalized != withoutTrailingSlash) {
      throw FlutterBuildError('SwiftPM binary artifact has unsafe ZIP path');
    }
    return normalized;
  }

  static bool _isWindowsSafeComponent(String value) {
    if (value.isEmpty || value.endsWith('.') || value.endsWith(' ')) {
      return false;
    }
    for (final codeUnit in value.codeUnits) {
      if (codeUnit < 0x20 ||
          codeUnit > 0x7e ||
          r'<>:"/\|?*'.codeUnits.contains(codeUnit)) {
        return false;
      }
    }
    final basename = value.split('.').first.toUpperCase();
    return basename != r'CONIN$' &&
        basename != r'CONOUT$' &&
        basename != r'CLOCK$' &&
        basename != 'CON' &&
        basename != 'PRN' &&
        basename != 'AUX' &&
        basename != 'NUL' &&
        !RegExp(r'^(COM|LPT)[1-9]$').hasMatch(basename);
  }
}

@internal
final class ValidatedArchiveEntry {
  const ValidatedArchiveEntry(this.file, this.name);

  final ArchiveFile file;
  final String name;
}

@internal
final class XcFrameworkLibrary {
  const XcFrameworkLibrary({
    required this.raw,
    required this.identifier,
    required this.libraryPath,
    required this.headersPath,
    required this.debugSymbolsPath,
    required this.platform,
    required this.variant,
    required this.architectures,
  });

  final Map<Object?, Object?> raw;
  final String identifier;
  final String libraryPath;
  final String? headersPath;
  final String? debugSymbolsPath;
  final String platform;
  final String? variant;
  final List<String> architectures;
}

@internal
final class InspectedXcFrameworkArchive {
  const InspectedXcFrameworkArchive({
    required this.entries,
    required this.plist,
    required this.library,
    required this.artifactDirectoryName,
    required this.selectedPrefix,
    required this.materializedBytes,
  });

  final List<ValidatedArchiveEntry> entries;
  final Map<Object?, Object?> plist;
  final XcFrameworkLibrary library;
  final String artifactDirectoryName;
  final String selectedPrefix;
  final int materializedBytes;
}
