// Original code (not a port of any upstream Provision source file). It
// automates the manual step documented in upstream's README.md
// ("Dependencies"): download the Apple Music Android APK and extract the
// two native ADI libraries from it. See NOTICE.md.

import 'dart:ffi';
import 'dart:io';

import 'package:apple_developer_kit/host/shared/apple_host_services.dart';
import 'package:apple_developer_kit/src/shared/adi/adi_architecture.dart';
import 'package:apple_developer_kit/src/shared/adi/elf/elf_reader.dart';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

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
  AdiLibraryFetcher({
    required this.cacheDir,
    required this.hostServices,
    required Abi abi,
    required http.Client Function() createClient,
  }) : _createClient = createClient,
       _architecture = AdiArchitecture.forAbi(abi);

  final AppleHostServices hostServices;
  final http.Client Function() _createClient;
  final AdiArchitecture _architecture;

  Directory get libraryDirectory =>
      hostServices.host.fileSystem.directory(_libraryPath);

  /// Directory the APK and extracted libraries are cached in.
  final String cacheDir;

  String get _libraryPath =>
      hostServices.host.paths.context.join(cacheDir, _architecture.apkAbi);

  static bool supportsAbi(Abi abi) => AdiArchitecture.tryForAbi(abi) != null;

  File get _apkFile => hostServices.host.fileSystem.file(
    hostServices.host.paths.context.join(cacheDir, 'applemusic.apk'),
  );

  /// SHA-256 of the downloaded APK is recorded next to it, so a future
  /// Apple Music version bump is at least *detectable* (not enforced
  /// yet — this just makes a silent upstream change visible).
  File get _apkShaSidecar => hostServices.host.fileSystem.file(
    hostServices.host.paths.context.join(cacheDir, 'applemusic.apk.sha256'),
  );

  /// Path the extracted `libCoreADI.so` is cached at.
  File get coreAdiFile => hostServices.host.fileSystem.file(
    hostServices.host.paths.context.join(_libraryPath, 'libCoreADI.so'),
  );

  /// Path the extracted `libstoreservicescore.so` is cached at.
  File get storeServicesFile => hostServices.host.fileSystem.file(
    hostServices.host.paths.context.join(
      _libraryPath,
      'libstoreservicescore.so',
    ),
  );

  bool _hasCachedLibraries() =>
      coreAdiFile.existsSync() &&
      storeServicesFile.existsSync() &&
      _apkShaSidecar.existsSync() &&
      _librariesMatchArchitecture();

  /// Ensures both native libraries are present in [cacheDir], downloading
  /// and extracting them first if needed.
  Future<AdiLibraryPaths> ensureLibraries() async {
    if (_hasCachedLibraries()) {
      return AdiLibraryPaths(
        coreAdiPath: coreAdiFile.path,
        storeServicesPath: storeServicesFile.path,
        apkSha256: _apkShaSidecar.readAsStringSync().trim(),
      );
    }

    await hostServices.host.fileSystem
        .directory(cacheDir)
        .create(recursive: true);
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
    final client = _createClient();
    var failed = false;
    try {
      final response = await client.get(Uri.parse(appleMusicApkUrl));
      if (response.statusCode != 200) {
        throw HttpException(
          'Failed to download Apple Music APK: HTTP ${response.statusCode}',
        );
      }
      await _apkFile.writeAsBytes(response.bodyBytes);
    } catch (_) {
      failed = true;
      rethrow;
    } finally {
      try {
        client.close();
      } catch (_) {
        if (!failed) rethrow;
      }
    }
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
      hostServices.host.fileSystem
          .file(hostServices.host.paths.context.join(_libraryPath, entry.key))
          .writeAsBytesSync(entry.value);
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

final class AdiLibraryResolver {
  AdiLibraryResolver({required this.hostServices});

  final AppleHostServices hostServices;

  Directory? resolve(String directory, {required Abi abi}) {
    final architecture = AdiArchitecture.forAbi(abi);
    final paths = hostServices.host.paths.context;
    final fileSystem = hostServices.host.fileSystem;
    final scopedPath = paths.join(directory, architecture.apkAbi);
    final scoped = fileSystem.directory(scopedPath);
    final selectedPath = scoped.existsSync() ? scopedPath : directory;
    final selected = fileSystem.directory(selectedPath);
    final files = [
      for (final name in _libraryNames)
        fileSystem.file(paths.join(selectedPath, name)),
    ];
    if (files.any((file) => !file.existsSync())) return null;
    for (final file in files) {
      ElfReader(
        file.readAsBytesSync(),
      ).validate(machine: architecture.elfMachine);
    }
    return selected;
  }
}
