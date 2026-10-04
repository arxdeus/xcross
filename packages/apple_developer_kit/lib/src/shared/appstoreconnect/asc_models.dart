/// Plain models for the JSON:API resources the App Store Connect endpoints
/// used here return (`{"data": {"id", "type", "attributes": {...}}}`).
library;

import 'package:meta/meta.dart';

/// A signed iOS Development certificate.
@immutable
final class AscCertificate {
  const AscCertificate({
    required this.id,
    required this.certificateContentBase64,
    required this.expirationDate,
    required this.serialNumber,
  });

  factory AscCertificate.fromJson(Map<String, dynamic> json) {
    final attributes = _attributesOf(json);
    return AscCertificate(
      id: json['id'] as String,
      certificateContentBase64: attributes['certificateContent'] as String,
      expirationDate: attributes['expirationDate'] as String?,
      serialNumber: attributes['serialNumber'] as String?,
    );
  }

  /// The certificate's App Store Connect resource id.
  final String id;

  /// Base64-encoded **DER** certificate content - not PEM. Wrap it (see
  /// `AscProvisioning.wrapDerAsPem`) before writing it out as a `.pem` or
  /// `.cer` file.
  final String certificateContentBase64;

  final String? expirationDate;
  final String? serialNumber;
}

/// A registered test device.
@immutable
final class AscDevice {
  const AscDevice({
    required this.id,
    required this.udid,
    required this.name,
    required this.status,
    this.deviceClass,
  });

  factory AscDevice.fromJson(Map<String, dynamic> json) {
    final attributes = _attributesOf(json);
    return AscDevice(
      id: json['id'] as String,
      udid: attributes['udid'] as String,
      name: attributes['name'] as String,
      status: attributes['status'] as String?,
      deviceClass: attributes['deviceClass'] as String?,
    );
  }

  /// The device's App Store Connect resource id.
  final String id;
  final String udid;
  final String name;
  final String? status;

  /// `IPHONE` / `IPAD` / `IPOD` / … — used to decide which devices belong
  /// in an `IOS_APP_DEVELOPMENT` profile (xtool filters the same way).
  final String? deviceClass;

  bool get supportsIosApps => switch (deviceClass?.toUpperCase()) {
    'IPHONE' || 'IPAD' || 'IPOD' => true,
    // Older payloads omit the class; keep the device so we don't drop the
    // UDID we just registered.
    _ => deviceClass == null,
  };
}

/// A registered app bundle id.
@immutable
final class AscBundleId {
  const AscBundleId({
    required this.id,
    required this.identifier,
    required this.name,
  });

  factory AscBundleId.fromJson(Map<String, dynamic> json) {
    final attributes = _attributesOf(json);
    return AscBundleId(
      id: json['id'] as String,
      identifier: attributes['identifier'] as String,
      name: attributes['name'] as String,
    );
  }

  /// The bundle id's App Store Connect resource id (distinct from
  /// [identifier], the actual `com.foo.bar` string).
  final String id;
  final String identifier;
  final String name;
}

/// An App Group a bundle id can be associated with, letting an app and its
/// extensions share a container.
@immutable
final class AscAppGroup {
  const AscAppGroup({
    required this.id,
    required this.identifier,
    required this.name,
  });

  factory AscAppGroup.fromJson(Map<String, dynamic> json) {
    final attributes = _attributesOf(json);
    return AscAppGroup(
      id: json['id'] as String,
      identifier: attributes['identifier'] as String,
      name: attributes['name'] as String? ?? '',
    );
  }

  /// The App Group's resource id, used to link it to a bundle id.
  final String id;

  /// The `group.com.foo` string carried in the entitlements.
  final String identifier;
  final String name;
}

/// A generated provisioning profile.
@immutable
final class AscProfile {
  const AscProfile({
    required this.id,
    required this.profileContentBase64,
    required this.uuid,
    required this.profileState,
    required this.expirationDate,
  });

  factory AscProfile.fromJson(Map<String, dynamic> json) {
    final attributes = _attributesOf(json);
    return AscProfile(
      id: json['id'] as String,
      profileContentBase64: attributes['profileContent'] as String,
      uuid: attributes['uuid'] as String?,
      profileState: attributes['profileState'] as String?,
      expirationDate: attributes['expirationDate'] as String?,
    );
  }

  /// The profile's App Store Connect resource id.
  final String id;

  /// Base64-encoded raw `.mobileprovision` bytes (a binary CMS/plist blob,
  /// not text) - decode and write it as-is, it is not PEM either.
  final String profileContentBase64;

  final String? uuid;
  final String? profileState;
  final String? expirationDate;
}

Map<String, dynamic> _attributesOf(Map<String, dynamic> json) =>
    (json['attributes'] as Map).cast<String, dynamic>();

/// A provisioning profile as listed for one bundle id: just enough to tell the
/// profiles xcross created from a pipeline's.
@immutable
final class AscProfileRef {
  const AscProfileRef({required this.id, required this.name, this.profileType});

  factory AscProfileRef.fromJson(Map<String, dynamic> json) {
    final attributes = _attributesOf(json);
    return AscProfileRef(
      id: json['id'] as String,
      name: attributes['name'] as String? ?? '',
      profileType: attributes['profileType'] as String?,
    );
  }

  /// The profile's App Store Connect resource id.
  final String id;

  /// The name the profile was created under, e.g. `xcross Development 1789…`
  /// or `MyApp ios_app_store 1789…`.
  final String name;

  /// e.g. `IOS_APP_DEVELOPMENT` or `IOS_APP_STORE`, null when not reported.
  final String? profileType;

  bool get isDevelopment => profileType == 'IOS_APP_DEVELOPMENT';
}
