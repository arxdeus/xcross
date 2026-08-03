// Original code (not a port of any upstream Provision source file). It
// automates the manual step documented in upstream's README.md
// ("Dependencies"): download the Apple Music Android APK and extract the
// two native ADI libraries from it. See NOTICE.md.

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// URL of the Apple Music Android APK, from which the ADI native
/// libraries are extracted (per upstream Provision's README.md).
const appleMusicApkUrl =
    'https://apps.mzstatic.com/content/android-apple-music-apk/applemusic.apk';

const _coreAdiEntry = 'lib/x86_64/libCoreADI.so';
const _storeServicesEntry = 'lib/x86_64/libstoreservicescore.so';

/// Downloads (if not already cached) the Apple Music APK and extracts the
/// two native ADI shared libraries (`libCoreADI.so`,
/// `libstoreservicescore.so`, x86_64 slice) it contains.
///
/// Apple's libraries themselves are never redistributed by this package;
/// they are downloaded on demand and cached locally, matching upstream's
/// documented approach.
class AdiLibraryFetcher {
  AdiLibraryFetcher({Directory? cacheDir})
    : cacheDir = cacheDir ?? _defaultCacheDir();

  /// Directory the APK and extracted libraries are cached in.
  final Directory cacheDir;

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
  File get coreAdiFile => File(p.join(cacheDir.path, 'libCoreADI.so'));

  /// Path the extracted `libstoreservicescore.so` is cached at.
  File get storeServicesFile =>
      File(p.join(cacheDir.path, 'libstoreservicescore.so'));

  /// Ensures both native libraries are present in [cacheDir], downloading
  /// and extracting them first if needed.
  ///
  /// Returns `(coreAdiPath, storeServicesPath, apkSha256)`, libraries in
  /// dependency-load order plus the cached APK's recorded SHA-256.
  Future<(String, String, String)> ensureLibraries() async {
    if (coreAdiFile.existsSync() &&
        storeServicesFile.existsSync() &&
        _apkShaSidecar.existsSync()) {
      return (
        coreAdiFile.path,
        storeServicesFile.path,
        _apkShaSidecar.readAsStringSync().trim(),
      );
    }

    await cacheDir.create(recursive: true);
    await _downloadApkIfNeeded();
    final apkSha256 = _recordApkHash();
    _extractLibraries();

    return (coreAdiFile.path, storeServicesFile.path, apkSha256);
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

    for (final entryName in [_coreAdiEntry, _storeServicesEntry]) {
      final entry = archive.findFile(entryName);
      if (entry == null) {
        throw StateError(
          'Apple Music APK is missing expected entry: $entryName',
        );
      }
      final outPath = p.join(cacheDir.path, p.basename(entryName));
      File(outPath).writeAsBytesSync(entry.content as List<int>);
    }
  }
}
