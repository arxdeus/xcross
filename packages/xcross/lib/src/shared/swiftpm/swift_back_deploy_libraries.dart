import 'dart:io';
import 'dart:typed_data';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/apple/mach_o.dart';

/// Xcode's "Copy Swift Standard Libraries" step (`swift-stdlib-tool`) for
/// the Swift runtime back-deployment libraries.
///
/// A Swift module built for an iOS older than the one that ships a runtime
/// feature links that feature's back-deployment library through `@rpath`,
/// for instance `@rpath/libswiftCompatibilitySpan.dylib` (weak) for `Span`
/// below iOS 26 (swift-collections 1.2 and later) or
/// `@rpath/libswift_Concurrency.dylib` below iOS 15. Runtime libraries the
/// OS already ships are linked as `/usr/lib/swift/...` instead, so an
/// `@rpath/libswift*.dylib` reference is exactly what needs embedding.
/// Xcode 26.6 copies each such library, and the ones they reference in
/// turn, from the toolchain's `usr/lib/swift-<version>/<platform>/` into
/// `.app/Frameworks` (measured: `libswiftCompatibilitySpan.dylib` from
/// `swift-6.2/iphoneos`, a loose dylib, the one exception to ITMS-90171).
///
/// One deliberate difference: Xcode copies the universal library as it is
/// (`arm64 arm64e` for the device), while this keeps only the slices of
/// the app's own executable, as `lipo -thin` would. xcross's code signer
/// signs thin Mach-O files only, and the slices themselves are unchanged.
///
/// The libraries come from the installed Darwin SDK, which carries the
/// toolchain's `swift-5.5` and `swift-6.2` trees since the installer copies
/// them (`sdkSwiftBackDeployRoots`); an SDK installed earlier lacks them,
/// and the build warns and goes on without them.
@internal
final class SwiftBackDeployLibraries {
  const SwiftBackDeployLibraries(this.fileSystem, this.paths);

  final HostFileSystemInterface fileSystem;
  final p.Context paths;

  static const _toolchain = [
    'Developer',
    'Toolchains',
    'XcodeDefault.xctoolchain',
  ];
  static final _rpathSwiftLibrary = RegExp(r'^@rpath/(libswift[^/]*\.dylib)$');
  static final _backDeployDirectory = RegExp(r'^swift-\d+(\.\d+)*$');

  /// The platform directory name for an SDK name such as `iphoneos26.5`:
  /// the name without its version, as Xcode's `PLATFORM_NAME`.
  static String platformOf(String sdkName) =>
      sdkName.replaceFirst(_sdkVersionSuffix, '');
  static final _sdkVersionSuffix = RegExp(r'[\d.]+$');

  /// The Darwin SDK bundle root holding the platform SDK at [sdkPath]
  /// (`<root>/Developer/Platforms/<P>.platform/Developer/SDKs/<S>.sdk`).
  static String sdkRootOf(p.Context paths, String sdkPath) {
    var root = sdkPath;
    for (var i = 0; i < 6; i++) {
      root = paths.dirname(root);
    }
    return root;
  }

  /// Embeds in `<bundleDir>/Frameworks` every Swift back-deployment library
  /// the Mach-O files of [bundleDir] reference through `@rpath`, taken from
  /// the Darwin SDK at [sdkRoot] for [platform] (`iphoneos` or
  /// `iphonesimulator`). Returns the libraries it wrote. A bundle without
  /// such references is left untouched. A library the SDK lacks is reported
  /// through [warn].
  Future<List<String>> embed({
    required String bundleDir,
    required String? sdkRoot,
    required String platform,
    void Function(String message)? warn,
  }) async {
    final binaries = _machOFiles(bundleDir);
    final pending = <String>{};
    final architectures = <(int, int)>{};
    final runner = _executable(bundleDir);
    for (final binary in binaries) {
      final slices = _slices(fileSystem.file(binary).readAsBytesSync());
      if (binary == runner) {
        architectures.addAll(slices.map((slice) => slice.architecture));
      }
      for (final slice in slices) {
        pending.addAll(_rpathSwiftLibraries(slice.bytes));
      }
    }
    if (pending.isEmpty) return const [];

    final frameworksDir = paths.join(bundleDir, 'Frameworks');
    final sources = sdkRoot == null
        ? const <String>[]
        : _sourceDirectories(sdkRoot, platform);
    final written = <String>[];
    final done = <String>{};
    final missing = <String>[];
    while (pending.isNotEmpty) {
      final name = pending.first;
      pending.remove(name);
      if (!done.add(name)) continue;
      final destination = paths.join(frameworksDir, name);
      if (fileSystem.file(destination).existsSync()) continue;
      final source = _find(sources, name);
      if (source == null) {
        missing.add(name);
        continue;
      }
      final bytes = _thin(
        fileSystem.file(source).readAsBytesSync(),
        architectures,
      );
      await fileSystem.directory(frameworksDir).create(recursive: true);
      await fileSystem.file(destination).writeAsBytes(bytes, flush: true);
      // Xcode's copy is `rwxr-xr-x`, as the toolchain's.
      fileSystem.makeExecutable(destination);
      written.add(destination);
      for (final slice in _slices(bytes)) {
        pending.addAll(
          _rpathSwiftLibraries(slice.bytes).where((n) => n != name),
        );
      }
    }
    if (missing.isNotEmpty) {
      final libraries = missing.join(', ');
      warn?.call(
        sources.isEmpty
            ? 'The app links the Swift back-deployment libraries $libraries, '
                  'which the installed Darwin SDK does not carry (it predates '
                  'them). Without them the app crashes on iOS versions that '
                  'lack these runtime features. Re-run `xcross sdk install` '
                  'once to embed them as Xcode does.'
            : 'The app links the Swift back-deployment libraries $libraries, '
                  'which the installed Darwin SDK does not carry for '
                  '$platform; they are not embedded.',
      );
    }
    return written;
  }

  /// `usr/lib/swift-<version>/<platform>` directories of the SDK, newest
  /// version first.
  List<String> _sourceDirectories(String sdkRoot, String platform) {
    final lib = paths.joinAll([sdkRoot, ..._toolchain, 'usr', 'lib']);
    final directory = fileSystem.directory(lib);
    if (!directory.existsSync()) return const [];
    final versions = <String>[
      for (final entity in directory.listSync())
        if (_backDeployDirectory.hasMatch(paths.basename(entity.path)) &&
            fileSystem
                .directory(paths.join(entity.path, platform))
                .existsSync())
          paths.join(entity.path, platform),
    ];
    List<int> version(String path) => paths
        .basename(paths.dirname(path))
        .substring('swift-'.length)
        .split('.')
        .map(int.parse)
        .toList();
    int compare(List<int> a, List<int> b) {
      for (var i = 0; i < a.length || i < b.length; i++) {
        final x = i < a.length ? a[i] : 0;
        final y = i < b.length ? b[i] : 0;
        if (x != y) return x.compareTo(y);
      }
      return 0;
    }

    return versions..sort((a, b) => compare(version(b), version(a)));
  }

  String? _find(List<String> sources, String name) {
    for (final source in sources) {
      final path = paths.join(source, name);
      if (fileSystem.file(path).existsSync()) return path;
    }
    return null;
  }

  String _executable(String bundleDir) => paths.join(bundleDir, 'Runner');

  /// The app executable and every Mach-O file under `Frameworks`, in a
  /// stable order. Links are not followed.
  List<String> _machOFiles(String bundleDir) {
    final files = <String>[];
    final runner = _executable(bundleDir);
    if (fileSystem.file(runner).existsSync()) files.add(runner);
    final frameworks = fileSystem.directory(
      paths.join(bundleDir, 'Frameworks'),
    );
    if (frameworks.existsSync()) {
      final found = <String>[
        for (final entity in frameworks.listSync(
          recursive: true,
          followLinks: false,
        ))
          if (entity is File && _hasMachOMagic(entity)) entity.path,
      ]..sort();
      files.addAll(found);
    }
    return files;
  }

  static bool _hasMachOMagic(File file) {
    final handle = file.openSync();
    try {
      final header = handle.readSync(4);
      if (header.length < 4) return false;
      final data = ByteData.sublistView(header);
      final little = data.getUint32(0, Endian.little);
      final big = data.getUint32(0);
      return little == MachOConstants.magic64 ||
          big == _fatMagic ||
          big == _fatMagic64;
    } finally {
      handle.closeSync();
    }
  }

  static const _fatMagic = 0xCAFE_BABE;
  static const _fatMagic64 = 0xCAFE_BABF;
  static const _cpuSubtypeMask = 0x00FF_FFFF;

  static const _lcLoadDylib = 0xC;
  static const _lcLoadWeakDylib = 0x8000_0018;
  static const _lcReexportDylib = 0x8000_001F;
  static const _lcLazyLoadDylib = 0x20;
  static const _lcLoadUpwardDylib = 0x8000_0023;
  static const _dylibCommands = {
    _lcLoadDylib,
    _lcLoadWeakDylib,
    _lcReexportDylib,
    _lcLazyLoadDylib,
    _lcLoadUpwardDylib,
  };

  /// The thin 64-bit slices of [bytes]: the file itself, or each member of
  /// a universal file. Anything else has no slices.
  static List<MachOSlice> _slices(Uint8List bytes) {
    if (bytes.length < 8) return const [];
    final data = ByteData.sublistView(bytes);
    if (data.getUint32(0, Endian.little) == MachOConstants.magic64) {
      return [
        MachOSlice((
          data.getUint32(4, Endian.little),
          data.getUint32(8, Endian.little) & _cpuSubtypeMask,
        ), bytes),
      ];
    }
    final magic = data.getUint32(0);
    if (magic != _fatMagic && magic != _fatMagic64) return const [];
    final wide = magic == _fatMagic64;
    final count = data.getUint32(4);
    final entrySize = wide ? 32 : 20;
    final slices = <MachOSlice>[];
    for (var i = 0; i < count; i++) {
      final entry = 8 + i * entrySize;
      if (entry + entrySize > bytes.length) break;
      final offset = wide
          ? data.getUint64(entry + 8)
          : data.getUint32(entry + 8);
      final size = wide
          ? data.getUint64(entry + 16)
          : data.getUint32(entry + 12);
      if (!MachOFile.rangeFits(offset, size, bytes.length)) continue;
      final slice = Uint8List.sublistView(bytes, offset, offset + size);
      if (slice.length < MachOConstants.headerSize64 ||
          ByteData.sublistView(slice).getUint32(0, Endian.little) !=
              MachOConstants.magic64) {
        continue;
      }
      slices.add(
        MachOSlice((
          data.getUint32(entry),
          data.getUint32(entry + 4) & _cpuSubtypeMask,
        ), slice),
      );
    }
    return slices;
  }

  /// The `@rpath/libswift*.dylib` libraries one thin slice loads.
  static List<String> _rpathSwiftLibraries(Uint8List slice) {
    final MachOFile file;
    try {
      file = MachOFile.parse(
        slice,
        invalid: (message) => throw FormatException(message),
      );
    } on FormatException {
      return const [];
    }
    final names = <String>[];
    for (final command in file.commands) {
      if (!_dylibCommands.contains(command.type) || command.size < 24) {
        continue;
      }
      final nameOffset = file.data.getUint32(command.offset + 8, Endian.little);
      if (nameOffset >= command.size) continue;
      final String name;
      try {
        name = file.nullTerminatedString(
          command.offset + nameOffset,
          command.offset + command.size,
          'dylib name',
        );
      } on FormatException {
        continue;
      }
      final match = _rpathSwiftLibrary.firstMatch(name);
      if (match != null) names.add(match.group(1)!);
    }
    return names;
  }

  /// [bytes] reduced to the slices of [architectures] (cpu type and
  /// subtype): a single matching slice becomes a thin file. A thin file, an
  /// unknown app architecture or no match leaves [bytes] as they are.
  static Uint8List _thin(Uint8List bytes, Set<(int, int)> architectures) {
    final data = ByteData.sublistView(bytes);
    final magic = bytes.length < 4 ? 0 : data.getUint32(0);
    if (magic != _fatMagic && magic != _fatMagic64) return bytes;
    if (architectures.isEmpty) return bytes;
    final kept = _slices(
      bytes,
    ).where((slice) => architectures.contains(slice.architecture)).toList();
    if (kept.length != 1) return bytes;
    return Uint8List.fromList(kept.single.bytes);
  }
}

/// One thin Mach-O slice: its `(cputype, cpusubtype)` and bytes.
@internal
final class MachOSlice {
  const MachOSlice(this.architecture, this.bytes);
  final (int, int) architecture;
  final Uint8List bytes;
}
