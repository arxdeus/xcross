import 'dart:typed_data';

import 'package:meta/meta.dart';

/// Everything the embedded signature is built from, other than the code image
/// itself. Signing runs two passes over these same inputs, so grouping them
/// makes it obvious that nothing changes between the passes.
@immutable
final class SignatureInputs {
  const SignatureInputs({
    required this.execSegmentLimit,
    required this.identifier,
    required this.teamIdentifier,
    required this.infoHash,
    required this.resourcesHash,
    required this.requirement,
    required this.xmlEntitlements,
    required this.derEntitlements,
    required this.isExecutable,
    required this.signingTime,
    required this.path,
  });

  final int execSegmentLimit;
  final String identifier;
  final String teamIdentifier;
  final Uint8List infoHash;
  final Uint8List resourcesHash;
  final Uint8List requirement;
  final Uint8List xmlEntitlements;
  final Uint8List? derEntitlements;
  final bool isExecutable;
  final DateTime signingTime;
  final String path;
}
