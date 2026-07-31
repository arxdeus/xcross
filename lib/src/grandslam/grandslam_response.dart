/// Shared GrandSlam plist response helpers: the `{"Status": {"ec", "em"},
/// "Response": {...}}` envelope every `gsService`/`o=...` operation call
/// uses (originally implemented for the provisioning handshake in
/// [AnisetteDataProvider], extracted here so the SRP login handshake
/// ([GrandSlamClient], `grandslam_login.dart`) can reuse it verbatim rather
/// than duplicating the same decode/error logic), plus small typed
/// field-extraction helpers for the `String`/`Data`/`int` fields GrandSlam
/// responses are made of.
library;

import 'dart:typed_data';

import 'package:propertylistserialization/propertylistserialization.dart';
import 'package:xcross/src/util/errors.dart';

/// A GrandSlam operation error: the response's `Status.ec` was non-zero.
/// Carries the numeric code separately from [message] so callers can
/// distinguish specific codes (e.g. `-21669`, "incorrect verification
/// code") without parsing the message string.
class GrandSlamOperationError extends XcrossError {
  GrandSlamOperationError(this.code, String em)
    : super('GrandSlam error $code: $em');

  final int code;
}

/// Decodes a GrandSlam `o=...` operation response body: a plist dict with
/// a `Status` dict (`ec`/`em`) as a sibling of a `Response` dict. Throws
/// [GrandSlamOperationError] if `ec != 0`, or [XcrossError] if the body
/// isn't a well-formed envelope.
Map<String, Object?> decodeGrandSlamResponse(String xml) {
  final decoded = decodePlist(xml, context: 'GrandSlam response');
  final status = decoded['Status'];
  if (status is Map) {
    final ec = status['ec'];
    if (ec is int && ec != 0) {
      throw GrandSlamOperationError(ec, '${status['em'] ?? 'unknown error'}');
    }
  }
  final response = decoded['Response'];
  if (response is! Map) {
    throw XcrossError('GrandSlam response missing "Response" dict');
  }
  return response.cast<String, Object?>();
}

/// Decodes a bare (no `Status`/`Response` envelope) plist dict, e.g. the
/// decrypted `spd` payload from `o=complete`.
Map<String, Object?> decodePlist(String xml, {String context = 'plist'}) {
  final Object decoded;
  try {
    decoded = PropertyListSerialization.propertyListWithString(xml);
  } on PropertyListException catch (e) {
    throw XcrossError('$context was not a plist: $e');
  }
  if (decoded is! Map) {
    throw XcrossError('$context was not a plist dictionary');
  }
  return decoded.cast<String, Object?>();
}

String stringField(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! String) {
    throw XcrossError('GrandSlam response missing "$key" (or not a string)');
  }
  return value;
}

int intField(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! int) {
    throw XcrossError('GrandSlam response missing "$key" (or not an int)');
  }
  return value;
}

/// A plist `<data>` field, decoded by `package:propertylistserialization`
/// as [ByteData]; converted here to the [Uint8List] the rest of this
/// codebase (and [SrpClient]) works with.
Uint8List dataField(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! ByteData) {
    throw XcrossError('GrandSlam response missing "$key" (or not binary data)');
  }
  return value.buffer.asUint8List(value.offsetInBytes, value.lengthInBytes);
}

Uint8List? optionalDataField(Map<String, Object?> map, String key) {
  if (!map.containsKey(key) || map[key] == null) return null;
  return dataField(map, key);
}

/// Wraps [bytes] as the [ByteData] `package:propertylistserialization`'s
/// plist writer requires for a `<data>` element (it does not accept a
/// plain [Uint8List]/`List<int>` in the object graph).
ByteData byteDataOf(Uint8List bytes) =>
    bytes.buffer.asByteData(bytes.offsetInBytes, bytes.length);
