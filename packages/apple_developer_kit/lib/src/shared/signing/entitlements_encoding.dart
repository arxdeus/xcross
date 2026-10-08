import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:apple_developer_kit/shared/errors/errors.dart';
import 'package:apple_developer_kit/src/shared/signing/bytes.dart';
import 'package:apple_developer_kit/src/shared/signing/code_signature.dart';
import 'package:apple_developer_kit/src/shared/signing/der.dart';
import 'package:apple_developer_kit/src/shared/signing/internal/plist_der_entry.dart';
import 'package:apple_developer_kit/src/shared/signing/macho_format.dart';
import 'package:meta/meta.dart';
import 'package:propertylistserialization/propertylistserialization.dart';

/// True when the entitlements grant `get-task-allow`, which the exec segment
/// must mirror with `CS_EXECSEG_ALLOW_UNSIGNED`.
@internal
@useResult
bool entitlementsAllowUnsigned(Uint8List xmlEntitlements) {
  final xml = utf8.decode(xmlEntitlements.sublist(csBlobHeaderLength));
  return RegExp(r'<key>get-task-allow</key>\s*<true\s*/>').hasMatch(xml);
}

/// Serializes [entitlements] as an XML plist inside a `CS_` blob.
@internal
@useResult
Uint8List buildEntitlementsXml(Map<String, Object?> entitlements, String path) {
  final normalized = _normalizePlist(entitlements, path, 'XML entitlements');
  try {
    final xml = PropertyListSerialization.stringWithPropertyList(normalized);
    return csBlob(
      csMagicEmbeddedEntitlements,
      utf8.encode(xml),
      path,
      'XML entitlements',
    );
  } on AppleError {
    rethrow;
  } on Object catch (error) {
    machoFail(path, 'XML entitlements', '$error');
  }
}

/// Rebuilds the plist with UTF-8-sorted keys so the XML is byte-deterministic
/// regardless of the caller's map iteration order.
Object _normalizePlist(Object? value, String path, String field) {
  if (value is bool || value is int || value is String || value is DateTime) {
    return value!;
  }
  if (value is Uint8List) return ByteData.sublistView(value);
  if (value is ByteData) {
    final copy = Uint8List.fromList(
      value.buffer.asUint8List(value.offsetInBytes, value.lengthInBytes),
    );
    return ByteData.sublistView(copy);
  }
  if (value is List<Object?>) {
    return [
      for (var index = 0; index < value.length; index++)
        _normalizePlist(value[index], path, '$field[$index]'),
    ];
  }
  if (value is Map<Object?, Object?>) {
    final result = SplayTreeMap<String, Object?>(compareUtf8);
    for (final entry in value.entries) {
      if (entry.key is! String) {
        machoFail(path, field, 'contains a non-string map key');
      }
      final key = entry.key! as String;
      result[key] = _normalizePlist(entry.value, path, '$field.$key');
    }
    return result;
  }
  machoFail(path, field, 'unsupported value type ${value.runtimeType}');
}

/// Serializes [entitlements] as Apple's DER entitlements blob: version 1
/// followed by the dictionary, all wrapped in `[APPLICATION 16]`.
@internal
@useResult
Uint8List buildDerEntitlements(Map<String, Object?> entitlements, String path) {
  final dictionary = _derValue(entitlements, path, 'DER entitlements');
  final body = Uint8List.fromList([
    ...Der.tlv(DerTag.integer, const [1]),
    ...dictionary,
  ]);
  final raw = Der.tlv(DerTag.application16, body);
  return csBlob(csMagicEmbeddedDerEntitlements, raw, path, 'DER entitlements');
}

/// Encodes one entitlement value. Dictionaries become `[16]`-tagged sequences
/// of key/value pairs, sorted by the UTF-8 bytes of the key.
Uint8List _derValue(Object? value, String path, String field) {
  if (value is bool) {
    return Uint8List.fromList([DerTag.boolean, 1, if (value) 0xff else 0]);
  }
  if (value is int) return _derInteger(value, path, field);
  if (value is String) return Der.tlv(DerTag.utf8String, utf8.encode(value));
  if (value is Uint8List) return Der.tlv(DerTag.octetString, value);
  if (value is ByteData) {
    return Der.tlv(
      DerTag.octetString,
      value.buffer.asUint8List(value.offsetInBytes, value.lengthInBytes),
    );
  }
  if (value is DateTime) return _derGeneralizedTime(value, path, field);
  if (value is List<Object?>) {
    return Der.tlv(DerTag.sequence, [
      for (var index = 0; index < value.length; index++)
        ..._derValue(value[index], path, '$field[$index]'),
    ]);
  }
  if (value is Map<Object?, Object?>) return _derDictionary(value, path, field);
  machoFail(path, field, 'unsupported value type ${value.runtimeType}');
}

Uint8List _derGeneralizedTime(DateTime value, String path, String field) {
  final utc = value.toUtc();
  if (utc.year < 0 || utc.year > 9999) {
    machoFail(path, field, 'date year is outside canonical GeneralizedTime');
  }
  String two(int part) => part.toString().padLeft(2, '0');
  final text =
      '${utc.year.toString().padLeft(4, '0')}'
      '${two(utc.month)}${two(utc.day)}${two(utc.hour)}'
      '${two(utc.minute)}${two(utc.second)}Z';
  return Der.tlv(DerTag.generalizedTime, ascii.encode(text));
}

Uint8List _derDictionary(
  Map<Object?, Object?> value,
  String path,
  String field,
) {
  final entries = <PlistDerEntry>[];
  for (final entry in value.entries) {
    if (entry.key is! String) {
      machoFail(path, field, 'contains a non-string map key');
    }
    entries.add(
      PlistDerEntry(
        key: Uint8List.fromList(utf8.encode(entry.key! as String)),
        value: entry.value,
      ),
    );
  }
  entries.sort((left, right) => compareBytes(left.key, right.key));
  return Der.tlv(DerTag.context16, [
    for (final entry in entries)
      ...Der.tlv(DerTag.sequence, [
        ...Der.tlv(DerTag.utf8String, entry.key),
        ..._derValue(entry.value, path, '$field.${utf8.decode(entry.key)}'),
      ]),
  ]);
}

/// Encodes a plist integer as a minimal signed 64-bit two's-complement
/// `INTEGER`. Unlike [Der.unsignedInteger] this must also express negatives,
/// so it trims redundant leading `0x00`/`0xff` octets by hand.
Uint8List _derInteger(int value, String path, String field) {
  const minimum = -0x8000_0000_0000_0000;
  const maximum = 0x7FFF_FFFF_FFFF_FFFF;
  if (value < minimum || value > maximum) {
    machoFail(path, field, 'integer is outside the signed 64-bit plist range');
  }
  final bytes = Uint8List(8);
  var current = value;
  for (var index = 7; index >= 0; index--) {
    bytes[index] = current & 0xff;
    current >>= 8;
  }
  var start = 0;
  while (start < 7 && _isRedundantSignOctet(bytes, start)) {
    start++;
  }
  return Der.tlv(DerTag.integer, Uint8List.sublistView(bytes, start));
}

bool _isRedundantSignOctet(Uint8List bytes, int index) {
  final nextIsNegative = bytes[index + 1] & 0x80 != 0;
  final isZeroPad = bytes[index] == 0 && !nextIsNegative;
  final isOnesPad = bytes[index] == 0xff && nextIsNegative;
  return isZeroPad || isOnesPad;
}
