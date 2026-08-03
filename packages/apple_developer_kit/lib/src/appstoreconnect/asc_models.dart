/// Plain models for the JSON:API resources the App Store Connect endpoints
/// used here return (`{"data": {"id", "type", "attributes": {...}}}`).
library;

/// A signed iOS Development certificate.
class AscCertificate {
  const AscCertificate({
    required this.id,
    required this.certificateContentBase64,
    required this.expirationDate,
    required this.serialNumber,
  });

  /// The certificate's App Store Connect resource id.
  final String id;

  /// Base64-encoded **DER** certificate content - not PEM. Wrap it (see
  /// `AscProvisioning.wrapDerAsPem`) before writing it out as a `.pem`/`.cer` file.
  final String certificateContentBase64;

  final String? expirationDate;
  final String? serialNumber;

  factory AscCertificate.fromJson(Map<String, dynamic> json) {
    final attributes = (json['attributes'] as Map).cast<String, dynamic>();
    return AscCertificate(
      id: json['id'] as String,
      certificateContentBase64: attributes['certificateContent'] as String,
      expirationDate: attributes['expirationDate'] as String?,
      serialNumber: attributes['serialNumber'] as String?,
    );
  }
}

/// A registered test device.
class AscDevice {
  const AscDevice({
    required this.id,
    required this.udid,
    required this.name,
    required this.status,
    this.deviceClass,
  });

  /// The device's App Store Connect resource id.
  final String id;
  final String udid;
  final String name;
  final String? status;

  /// `IPHONE` / `IPAD` / `IPOD` / … — used to decide which devices belong
  /// in an `IOS_APP_DEVELOPMENT` profile (xtool filters the same way).
  final String? deviceClass;

  bool get supportsIosApps {
    switch (deviceClass?.toUpperCase()) {
      case 'IPHONE':
      case 'IPAD':
      case 'IPOD':
        return true;
      default:
        // Older payloads omit the class; keep the device so we don't drop
        // the UDID we just registered.
        return deviceClass == null;
    }
  }

  factory AscDevice.fromJson(Map<String, dynamic> json) {
    final attributes = (json['attributes'] as Map).cast<String, dynamic>();
    return AscDevice(
      id: json['id'] as String,
      udid: attributes['udid'] as String,
      name: attributes['name'] as String,
      status: attributes['status'] as String?,
      deviceClass: attributes['deviceClass'] as String?,
    );
  }
}

/// A registered app bundle id.
class AscBundleId {
  const AscBundleId({
    required this.id,
    required this.identifier,
    required this.name,
  });

  /// The bundle id's App Store Connect resource id (distinct from
  /// [identifier], the actual `com.foo.bar` string).
  final String id;
  final String identifier;
  final String name;

  factory AscBundleId.fromJson(Map<String, dynamic> json) {
    final attributes = (json['attributes'] as Map).cast<String, dynamic>();
    return AscBundleId(
      id: json['id'] as String,
      identifier: attributes['identifier'] as String,
      name: attributes['name'] as String,
    );
  }
}

/// A generated provisioning profile.
class AscProfile {
  const AscProfile({
    required this.id,
    required this.profileContentBase64,
    required this.uuid,
    required this.profileState,
    required this.expirationDate,
  });

  /// The profile's App Store Connect resource id.
  final String id;

  /// Base64-encoded raw `.mobileprovision` bytes (a binary CMS/plist blob,
  /// not text) - decode and write it as-is, it is not PEM either.
  final String profileContentBase64;

  final String? uuid;
  final String? profileState;
  final String? expirationDate;

  factory AscProfile.fromJson(Map<String, dynamic> json) {
    final attributes = (json['attributes'] as Map).cast<String, dynamic>();
    return AscProfile(
      id: json['id'] as String,
      profileContentBase64: attributes['profileContent'] as String,
      uuid: attributes['uuid'] as String?,
      profileState: attributes['profileState'] as String?,
      expirationDate: attributes['expirationDate'] as String?,
    );
  }
}
