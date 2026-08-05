/// Shared decoding for GrandSlam plist responses.
///
/// Every `gsService`/`o=...` call answers with a
/// `{"Response": {"Status": {"ec", "em"}, ...}}` envelope; the encrypted
/// payloads inside it are bare dicts. Both shapes, plus the typed field
/// accessors GrandSlam responses are made of, live here so the
/// provisioning, SRP login, and app-token layers decode identically.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:apple_developer_kit/src/errors.dart';
import 'package:meta/meta.dart';
import 'package:propertylistserialization/propertylistserialization.dart';

/// A GrandSlam operation error: the response's `Status.ec` was non-zero.
/// [code] is kept separate from the message so callers can recognise
/// specific codes (e.g. `-21669`, "incorrect verification code").
class GrandSlamOperationError extends AppleError {
  const GrandSlamOperationError(this.code, String em)
    : super('GrandSlam error $code: $em');

  final int code;
}

@internal
abstract final class GrandSlamResponse {
  /// Decodes an `o=...` operation response body and unwraps `Response`.
  ///
  /// Apple nests `Status` inside `Response`; the older sibling placement
  /// stays accepted for compatibility. Throws [GrandSlamOperationError]
  /// when `ec != 0`, or [AppleError] for a malformed envelope.
  @useResult
  static Map<String, Object?> decodeGrandSlamResponse(String xml) {
    final decoded = decodePlist(xml, context: 'GrandSlam response');
    final response = decoded['Response'];
    if (response is! Map<Object?, Object?>) {
      throw const AppleError('GrandSlam response missing "Response" dict');
    }
    final status = response['Status'] ?? decoded['Status'];
    if (status is Map<Object?, Object?>) {
      final ec = status['ec'];
      if (ec is int && ec != 0) {
        throw GrandSlamOperationError(ec, '${status['em'] ?? 'unknown error'}');
      }
    }
    return response.cast<String, Object?>();
  }

  /// Decodes a bare plist dict, e.g. the decrypted `spd` payload from
  /// `o=complete`. Apple sometimes sends the `<dict>` fragment alone, so a
  /// missing plist header/DOCTYPE is re-wrapped before parsing.
  @useResult
  static Map<String, Object?> decodePlist(
    String xml, {
    String context = 'plist',
  }) {
    final fragment = xml.trim();
    final source = fragment.startsWith('<dict>') && fragment.endsWith('</dict>')
        ? '<?xml version="1.0" encoding="UTF-8"?>\n'
              '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
              '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
              '<plist version="1.0">$fragment</plist>'
        : xml;
    final Object decoded;
    try {
      decoded = PropertyListSerialization.propertyListWithString(source);
    } on PropertyListException catch (e) {
      throw AppleError('$context was not a plist: $e');
    }
    return _plistMap(decoded, context);
  }

  /// Decodes raw plist bytes in either Apple's binary (`bplist00`) or XML
  /// representation - encrypted GrandSlam payloads are opaque bytes, so
  /// the server may use either.
  @useResult
  static Map<String, Object?> decodePlistBytes(
    Uint8List bytes, {
    String context = 'plist',
  }) {
    if (bytes.length < 8 || ascii.decode(bytes.sublist(0, 8)) != 'bplist00') {
      return decodePlist(utf8.decode(bytes), context: context);
    }
    final Object decoded;
    try {
      decoded = PropertyListSerialization.propertyListWithData(
        byteDataOf(bytes),
      );
    } on Object catch (e) {
      throw AppleError('$context was not a plist: $e');
    }
    return _plistMap(decoded, context);
  }

  static Map<String, Object?> _plistMap(Object decoded, String context) {
    if (decoded is! Map) {
      throw AppleError('$context was not a plist dictionary');
    }
    return decoded.cast<String, Object?>();
  }

  @useResult
  static String stringField(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value is! String) {
      throw AppleError('GrandSlam response missing "$key" (or not a string)');
    }
    return value;
  }

  @useResult
  static int intField(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value is! int) {
      throw AppleError('GrandSlam response missing "$key" (or not an int)');
    }
    return value;
  }

  /// A plist `<data>` field. `package:propertylistserialization` decodes
  /// those as [ByteData]; the rest of this package works in [Uint8List].
  @useResult
  static Uint8List dataField(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value is! ByteData) {
      throw AppleError(
        'GrandSlam response missing "$key" (or not binary data)',
      );
    }
    return value.buffer.asUint8List(value.offsetInBytes, value.lengthInBytes);
  }

  @useResult
  static Uint8List? optionalDataField(Map<String, Object?> map, String key) =>
      map[key] == null ? null : dataField(map, key);

  /// Wraps [bytes] as the [ByteData] the plist writer requires for a
  /// `<data>` element - it rejects a plain [Uint8List]/`List<int>`.
  @useResult
  static ByteData byteDataOf(Uint8List bytes) =>
      bytes.buffer.asByteData(bytes.offsetInBytes, bytes.length);
}
