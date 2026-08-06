import 'dart:io';

import 'package:basic_utils/basic_utils.dart';
import 'package:meta/meta.dart';
import 'package:posix/posix.dart' as posix;

/// Generates the RSA keypair + PKCS#10 CSR needed to request a new signing
/// certificate from App Store Connect.
///
/// The private key never leaves the caller's machine - Apple only ever sees
/// the CSR (a public-key proof of possession) and hands back a signed
/// certificate. The private key must be persisted locally forever after,
/// since it's what `zsign`-style tooling will need later to actually sign a
/// build with the certificate Apple returns.
abstract final class AscCsr {
  /// Generates a fresh 2048-bit RSA keypair and a CSR for it.
  @useResult
  static AscGeneratedCsr generate({String commonName = 'xcross Development'}) {
    final keyPair = CryptoUtils.generateRSAKeyPair();
    final privateKey = keyPair.privateKey as RSAPrivateKey;
    final publicKey = keyPair.publicKey as RSAPublicKey;
    final csrPem = X509Utils.generateRsaCsrPem(
      {'CN': commonName},
      privateKey,
      publicKey,
    );
    return AscGeneratedCsr(
      privateKey: privateKey,
      publicKey: publicKey,
      csrPem: csrPem,
    );
  }

  /// PEM-encodes [privateKey] (PKCS#8) for persisting to disk.
  @useResult
  static String privateKeyToPem(RSAPrivateKey privateKey) =>
      CryptoUtils.encodeRSAPrivateKeyToPem(privateKey);

  /// Writes [pem] to [path] and, on POSIX platforms, restricts its
  /// permissions to owner-only (`chmod 600`) since it's a private signing
  /// key. `posix` is a no-op stub on non-POSIX hosts (e.g. Windows), which
  /// has no equivalent via `dart:io` alone.
  static Future<void> writePrivateKeyPem(String path, String pem) async {
    final file = File(path);
    await file.writeAsString(pem);
    if (!Platform.isWindows && posix.isPosixSupported) {
      posix.chmod(path, '0600');
    }
  }
}

/// A freshly generated RSA keypair and its PKCS#10 CSR, from [AscCsr.generate].
@immutable
final class AscGeneratedCsr {
  const AscGeneratedCsr({
    required this.privateKey,
    required this.publicKey,
    required this.csrPem,
  });

  final RSAPrivateKey privateKey;
  final RSAPublicKey publicKey;
  final String csrPem;
}
