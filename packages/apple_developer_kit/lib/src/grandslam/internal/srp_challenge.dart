import 'dart:typed_data';

import 'package:meta/meta.dart';

/// What `o=init` hands back: everything needed to answer the challenge.
@immutable
final class SrpChallenge {
  const SrpChallenge({
    required this.protocol,
    required this.cookie,
    required this.salt,
    required this.iterations,
    required this.serverPublicKey,
  });

  final String protocol;
  final String cookie;
  final Uint8List salt;
  final int iterations;
  final Uint8List serverPublicKey;
}
