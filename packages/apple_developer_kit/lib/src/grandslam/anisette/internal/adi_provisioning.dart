import 'dart:typed_data';

import 'package:apple_developer_kit/src/adi/adi_client.dart';

/// Apple's sentinel `dsId` for machine-level (not-yet-signed-in) ADI
/// identity, used for both provisioning and every `requestOTP`.
const int kAdiMachineDsId = -2;

/// Builds the [AdiProvisioning] backing an `AnisetteDataProvider`.
typedef AdiProvisioningFactory =
    AdiProvisioning Function({
      required String adiLibraryDirectory,
      required String provisioningPath,
      required String identifier,
    });

/// The slice of `AdiClient` an anisette provider drives, extracted so
/// tests can substitute a fake instead of the real (Linux) native ADI
/// library.
abstract interface class AdiProvisioning {
  Future<bool> isMachineProvisioned(int dsId);

  Future<AdiClientProvisioningIntermediateMetadata> startProvisioning(
    int dsId,
    Uint8List serverProvisioningIntermediateMetadata,
  );

  Future<void> endProvisioning(
    int session,
    Uint8List persistentTokenMetadata,
    Uint8List trustKey,
  );

  Future<AdiOneTimePassword> requestOTP(int dsId);
}
