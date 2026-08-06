import 'dart:typed_data';

import 'package:apple_developer_kit/src/adi/adi_client.dart';
import 'package:apple_developer_kit/src/grandslam/anisette/internal/adi_provisioning.dart';

/// [AdiProvisioning] backed by a real [AdiClient].
final class RealAdiProvisioning implements AdiProvisioning {
  RealAdiProvisioning(this._client);

  final AdiClient _client;

  @override
  Future<bool> isMachineProvisioned(int dsId) =>
      _client.isMachineProvisioned(dsId);

  @override
  Future<AdiClientProvisioningIntermediateMetadata> startProvisioning(
    int dsId,
    Uint8List serverProvisioningIntermediateMetadata,
  ) => _client.startProvisioning(dsId, serverProvisioningIntermediateMetadata);

  @override
  Future<void> endProvisioning(
    int session,
    Uint8List persistentTokenMetadata,
    Uint8List trustKey,
  ) => _client.endProvisioning(session, persistentTokenMetadata, trustKey);

  @override
  Future<AdiOneTimePassword> requestOTP(int dsId) => _client.requestOTP(dsId);
}
