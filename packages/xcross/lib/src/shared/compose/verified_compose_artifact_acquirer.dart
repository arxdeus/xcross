import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/compose/compose_install_effects.dart';
import 'package:xcross/src/shared/errors/errors.dart';

@internal
final class VerifiedComposeArtifactAcquirer {
  const VerifiedComposeArtifactAcquirer({
    required this.downloadToFile,
    required this.digestFile,
    required this.extractArchive,
  });
  final DownloadToFile downloadToFile;
  final DigestFile digestFile;
  final ExtractArchive extractArchive;
  String requireDigest(String artifact, String? expectedSha256) {
    if (expectedSha256 == null) {
      throw XcrossError(
        'No pinned SHA-256 digest for Kotlin/Native $artifact.',
      );
    }
    return expectedSha256;
  }

  Future<void> verifyDigest(File file, String expectedSha256) async {
    final artifact = p.basename(file.path);
    final actualSha256 = await digestFile(file);
    if (actualSha256.toLowerCase() != expectedSha256.toLowerCase()) {
      throw XcrossError(
        'Kotlin/Native archive SHA-256 mismatch for $artifact: expected $expectedSha256, got $actualSha256.',
      );
    }
  }

  Future<void> extract(File archive, Directory destination) =>
      extractArchive(archive, destination);
}

@internal
Future<String> digestComposeArtifact(File file) =>
    sha256.bind(file.openRead()).first.then((digest) => digest.toString());
