// Original code (not a port of any upstream Provision source file). It
// automates the manual step documented in upstream's README.md
// ("Dependencies"): download the Apple Music Android APK and extract the
// two native ADI libraries from it. See NOTICE.md.

import 'dart:ffi';
import 'dart:io';

import 'package:apple_developer_kit/src/adi/adi_architecture.dart';
import 'package:apple_developer_kit/src/adi/elf/elf_reader.dart';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// Paths to the extracted ADI native libraries, in dependency-load order,
/// plus the cached APK's recorded SHA-256.
@immutable
final class AdiLibraryPaths {
  const AdiLibraryPaths({
    required this.coreAdiPath,
    required this.storeServicesPath,
    required this.apkSha256,
  });

  final String coreAdiPath;
  final String storeServicesPath;
  final String apkSha256;
}

/// URL of the Apple Music Android APK, from which the ADI native
/// libraries are extracted (per upstream Provision's README.md).
const appleMusicApkUrl =
    'https://apps.mzstatic.com/content/android-apple-music-apk/applemusic.apk';

const _libraryNames = ['libCoreADI.so', 'libstoreservicescore.so'];

/// Downloads (if not already cached) the Apple Music APK and extracts the
/// two native ADI shared libraries (`libCoreADI.so`,
/// `libstoreservicescore.so`, matching the host ABI) it contains.
///
/// Apple's libraries themselves are never redistributed by this package;
/// they are downloaded on demand and cached locally, matching upstream's
/// documented approach.
class AdiLibraryFetcher {
  AdiLibraryFetcher({Directory? cacheDir, Abi? abi})
    : cacheDir = cacheDir ?? _defaultCacheDir(),
      _architecture = AdiArchitecture.forAbi(abi ?? Abi.current());

  final AdiArchitecture _architecture;

  Directory get libraryDirectory =>
      Directory(p.join(cacheDir.path, _architecture.apkAbi));

  /// Directory the APK and extracted libraries are cached in.
  final Directory cacheDir;

  static bool supportsAbi(Abi abi) => AdiArchitecture.tryForAbi(abi) != null;

  static Directory? resolveLibraryDirectory(Directory directory, {Abi? abi}) {
    final architecture = AdiArchitecture.forAbi(abi ?? Abi.current());
    final scoped = Directory(p.join(directory.path, architecture.apkAbi));
    final selected = scoped.existsSync() ? scoped : directory;
    final files = [
      for (final name in _libraryNames) File(p.join(selected.path, name)),
    ];
    if (files.any((file) => !file.existsSync())) return null;
    for (final file in files) {
      ElfReader(
        file.readAsBytesSync(),
      ).validate(machine: architecture.elfMachine);
    }
    return selected;
  }

  static Directory _defaultCacheDir() {
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home == null) {
      throw StateError('Cannot determine a home directory (HOME is not set).');
    }
    return Directory(p.join(home, '.cache', 'provision_dart'));
  }

  File get _apkFile => File(p.join(cacheDir.path, 'applemusic.apk'));

  /// SHA-256 of the downloaded APK is recorded next to it, so a future
  /// Apple Music version bump is at least *detectable* (not enforced
  /// yet — this just makes a silent upstream change visible).
  File get _apkShaSidecar => File('${_apkFile.path}.sha256');

  /// Path the extracted `libCoreADI.so` is cached at.
  File get coreAdiFile => File(p.join(libraryDirectory.path, 'libCoreADI.so'));

  /// Path the extracted `libstoreservicescore.so` is cached at.
  File get storeServicesFile =>
      File(p.join(libraryDirectory.path, 'libstoreservicescore.so'));

  /// Ensures both native libraries are present in [cacheDir], downloading
  /// and extracting them first if needed.
  Future<AdiLibraryPaths> ensureLibraries() async {
    if (coreAdiFile.existsSync() &&
        storeServicesFile.existsSync() &&
        _apkShaSidecar.existsSync() &&
        _librariesMatchArchitecture()) {
      return AdiLibraryPaths(
        coreAdiPath: coreAdiFile.path,
        storeServicesPath: storeServicesFile.path,
        apkSha256: _apkShaSidecar.readAsStringSync().trim(),
      );
    }

    await cacheDir.create(recursive: true);
    await _downloadApkIfNeeded();
    final apkSha256 = _recordApkHash();
    _extractLibraries();
    _validateLibraries();

    return AdiLibraryPaths(
      coreAdiPath: coreAdiFile.path,
      storeServicesPath: storeServicesFile.path,
      apkSha256: apkSha256,
    );
  }

  String _recordApkHash() {
    final hash = sha256.convert(_apkFile.readAsBytesSync()).toString();
    _apkShaSidecar.writeAsStringSync(hash);
    return hash;
  }

  Future<void> _downloadApkIfNeeded() async {
    if (_apkFile.existsSync()) return;
    final response = await http.get(Uri.parse(appleMusicApkUrl));
    if (response.statusCode != 200) {
      throw HttpException(
        'Failed to download Apple Music APK: HTTP ${response.statusCode}',
      );
    }
    await _apkFile.writeAsBytes(response.bodyBytes);
  }

  void _extractLibraries() {
    final archive = ZipDecoder().decodeBytes(_apkFile.readAsBytesSync());

    final entries = <String, List<int>>{};
    for (final name in _libraryNames) {
      final entryName = 'lib/${_architecture.apkAbi}/$name';
      final entry = archive.findFile(entryName);
      if (entry == null) {
        throw StateError(
          'Apple Music APK is missing expected entry: $entryName',
        );
      }
      final bytes = entry.content;
      ElfReader(bytes).validate(machine: _architecture.elfMachine);
      entries[name] = bytes;
    }
    libraryDirectory.createSync(recursive: true);
    for (final entry in entries.entries) {
      File(
        p.join(libraryDirectory.path, entry.key),
      ).writeAsBytesSync(entry.value);
    }
  }

  bool _librariesMatchArchitecture() {
    try {
      _validateLibraries();
      return true;
    } on FormatException {
      return false;
    }
  }

  void _validateLibraries() {
    for (final file in [coreAdiFile, storeServicesFile]) {
      ElfReader(
        file.readAsBytesSync(),
      ).validate(machine: _architecture.elfMachine);
    }
  }
}
