import 'dart:convert';
import 'dart:typed_data';

import 'package:apple_developer_kit/src/signing/bytes.dart';
import 'package:meta/meta.dart';

/// ASN.1 identifier octets, in the constructed/primitive form each value is
/// actually encoded with.
///
/// The universal tags below are the low-tag-number form: class bits in 7-8,
/// the constructed bit in 6, and the tag number in bits 1-5. Context-specific
/// tags therefore start at `0xa0` (constructed, class `10`) and Apple's DER
/// entitlements use `0x70` (application-class constructed 16) as their
/// outermost wrapper.
@internal
abstract final class DerTag {
  static const int boolean = 0x01;
  static const int integer = 0x02;
  static const int bitString = 0x03;
  static const int octetString = 0x04;
  static const int null_ = 0x05;
  static const int objectIdentifier = 0x06;
  static const int utf8String = 0x0c;
  static const int utcTime = 0x17;
  static const int generalizedTime = 0x18;
  static const int sequence = 0x30;
  static const int set = 0x31;

  /// `[0]` explicit, used for CMS content, signed attributes, and certificates.
  static const int context0 = 0xa0;

  /// `[1]` explicit, used for CMS revocation data.
  static const int context1 = 0xa1;

  /// `[APPLICATION 16]`, the outer wrapper of Apple's DER entitlements blob.
  static const int application16 = 0x70;

  /// `[16]` context-specific constructed, Apple's DER entitlement dictionary.
  static const int context16 = 0xb0;
}

/// DER writers. Every helper emits definite-length, canonical encodings.
@internal
abstract final class Der {
  /// Encodes one tag-length-value triple.
  @useResult
  static Uint8List tlv(int tag, Iterable<int> value) {
    final body = value is Uint8List
        ? value
        : Uint8List.fromList(value.toList());
    return Uint8List.fromList([tag, ..._length(body.length), ...body]);
  }

  /// Encodes a definite length: short form below 128, else big-endian long
  /// form prefixed with `0x80 | byteCount`.
  static List<int> _length(int value) {
    if (value < 128) return [value];
    final bytes = <int>[];
    var remaining = value;
    while (remaining > 0) {
      bytes.insert(0, remaining & 0xff);
      remaining >>= 8;
    }
    return [0x80 | bytes.length, ...bytes];
  }

  @useResult
  static Uint8List sequence(Iterable<Uint8List> values) =>
      tlv(DerTag.sequence, _concat(values));

  /// Encodes a `SET OF`, whose members DER requires to be sorted by encoding.
  @useResult
  static Uint8List setOf(Iterable<Uint8List> values) =>
      tlv(DerTag.set, sortedContent(values));

  @useResult
  static Uint8List octetString(List<int> bytes) =>
      tlv(DerTag.octetString, bytes);

  /// Encodes a non-negative `INTEGER` in minimal two's-complement form.
  @useResult
  static Uint8List unsignedInteger(int value) {
    if (value < 0) throw ArgumentError.value(value, 'value');
    final bytes = <int>[];
    var remaining = value;
    do {
      bytes.insert(0, remaining & 0xff);
      remaining >>= 8;
    } while (remaining != 0);
    if (bytes.first >= 0x80) bytes.insert(0, 0);
    return tlv(DerTag.integer, bytes);
  }

  /// Encodes a timestamp as `UTCTime` inside 1950-2049 and `GeneralizedTime`
  /// outside it, matching the CMS `signingTime` rule in RFC 5652 11.3.
  @useResult
  static Uint8List time(DateTime value) {
    final utc = value.toUtc();
    String two(int part) => part.toString().padLeft(2, '0');
    if (utc.year >= 1950 && utc.year <= 2049) {
      return tlv(
        DerTag.utcTime,
        ascii.encode(
          '${two(utc.year % 100)}${two(utc.month)}${two(utc.day)}'
          '${two(utc.hour)}${two(utc.minute)}${two(utc.second)}Z',
        ),
      );
    }
    return tlv(
      DerTag.generalizedTime,
      ascii.encode(
        '${utc.year.toString().padLeft(4, '0')}${two(utc.month)}${two(utc.day)}'
        '${two(utc.hour)}${two(utc.minute)}${two(utc.second)}Z',
      ),
    );
  }

  /// Encodes a dotted object identifier.
  ///
  /// The first two arcs share one base-128 sub-identifier (`arc0 * 40 + arc1`),
  /// so arc 0 is limited to 0-2 and arc 1 to 0-39 unless arc 0 is 2.
  @useResult
  static Uint8List oid(String value) {
    final arcs = value.split('.').map(int.parse).toList();
    if (arcs.length < 2 ||
        arcs.first < 0 ||
        arcs.first > 2 ||
        arcs[1] < 0 ||
        (arcs.first < 2 && arcs[1] >= 40)) {
      throw ArgumentError.value(value, 'value', 'invalid object identifier');
    }
    final body = <int>[
      ..._base128(arcs.first * 40 + arcs[1]),
      for (final arc in arcs.skip(2)) ..._base128(arc),
    ];
    return tlv(DerTag.objectIdentifier, body);
  }

  /// Encodes one OID arc as base-128 with the continuation bit set on all but
  /// the final octet.
  static List<int> _base128(int value) {
    if (value < 0) throw ArgumentError.value(value, 'value');
    final bytes = <int>[value & 0x7f];
    var remaining = value >> 7;
    while (remaining > 0) {
      bytes.insert(0, (remaining & 0x7f) | 0x80);
      remaining >>= 7;
    }
    return bytes;
  }

  /// Encodes an `AlgorithmIdentifier`.
  ///
  /// SHA-256 digest algorithms omit the absent-parameters `NULL`, while
  /// `rsaEncryption` requires it (RFC 4055 2.1, RFC 3370 3.2).
  @useResult
  static Uint8List algorithmIdentifier(
    String algorithm, {
    bool includeNull = true,
  }) =>
      sequence([oid(algorithm), if (includeNull) tlv(DerTag.null_, const [])]);

  /// Encodes one CMS signed attribute: an OID paired with a `SET OF` values.
  @useResult
  static Uint8List attribute(String algorithm, List<Uint8List> values) =>
      sequence([oid(algorithm), setOf(values)]);

  static Uint8List _concat(Iterable<Uint8List> values) =>
      Uint8List.fromList([for (final value in values) ...value]);

  /// Concatenates [values] after sorting them by encoding, as `SET OF` and the
  /// CMS certificate set both require.
  @useResult
  static Uint8List sortedContent(Iterable<Uint8List> values) {
    final sorted = values.map(Uint8List.fromList).toList()..sort(compareBytes);
    return _concat(sorted);
  }

  /// Reads exactly one [tag]-tagged value that spans all of [bytes].
  static DerValue single(Uint8List bytes, int tag, String context) {
    final reader = DerReader(bytes);
    final value = reader.read(tag, context);
    reader.requireDone(context);
    return value;
  }

  /// Reads the OID out of an `AlgorithmIdentifier`, allowing only an absent or
  /// explicitly-`NULL` parameter.
  @useResult
  static String algorithmOid(DerValue algorithm, String context) {
    final reader = algorithm.reader();
    final algorithmOid = oidValue(
      reader.read(DerTag.objectIdentifier, '$context OID'),
    );
    if (!reader.isDone) {
      final parameters = reader.read(null, '$context parameters');
      if (parameters.tag != DerTag.null_ || parameters.value.isNotEmpty) {
        throw FormatException('$context has unsupported parameters');
      }
    }
    reader.requireDone(context);
    return algorithmOid;
  }

  /// Decodes an `OBJECT IDENTIFIER` value into dotted form.
  @useResult
  static String oidValue(DerValue value) {
    if (value.value.isEmpty) throw const FormatException('empty OID');
    final subIdentifiers = <BigInt>[];
    var current = BigInt.zero;
    var continued = false;
    for (final byte in value.value) {
      current = (current << 7) | BigInt.from(byte & 0x7f);
      continued = byte & 0x80 != 0;
      if (!continued) {
        subIdentifiers.add(current);
        current = BigInt.zero;
      }
    }
    if (continued || subIdentifiers.isEmpty) {
      throw const FormatException('unterminated OID');
    }
    // The first sub-identifier packs arcs 0 and 1: values below 40 mean arc
    // 0 is 0, below 80 mean arc 0 is 1, and everything else means arc 0 is 2.
    final first = subIdentifiers.first;
    final firstArc = first < BigInt.from(40)
        ? BigInt.zero
        : first < BigInt.from(80)
        ? BigInt.one
        : BigInt.two;
    final secondArc = first - firstArc * BigInt.from(40);
    return [firstArc, secondArc, ...subIdentifiers.skip(1)].join('.');
  }

  /// Decodes a strictly-positive, minimally-encoded `INTEGER`.
  @useResult
  static BigInt positiveInteger(DerValue value, String context) {
    final bytes = value.value;
    if (bytes.isEmpty || bytes.first >= 0x80) {
      throw FormatException('$context is not a positive integer');
    }
    if (bytes.length > 1 && bytes.first == 0 && bytes[1] < 0x80) {
      throw FormatException('$context has redundant leading zeroes');
    }
    var result = BigInt.zero;
    for (final byte in bytes) {
      result = (result << 8) | BigInt.from(byte);
    }
    return result;
  }
}

/// A cursor over a DER container that rejects every non-canonical encoding:
/// high-tag-number form, indefinite lengths, non-minimal lengths, and values
/// that overrun their parent.
@internal
class DerReader {
  DerReader(this._bytes, [int start = 0, int? end])
    : _offset = start,
      _end = end ?? _bytes.length {
    if (start < 0 || _end < start || _end > _bytes.length) {
      throw const FormatException('invalid DER bounds');
    }
  }

  final Uint8List _bytes;
  int _offset;
  final int _end;

  bool get isDone => _offset == _end;

  @useResult
  int peekTag() {
    if (isDone) throw const FormatException('unexpected end of DER');
    return _bytes[_offset];
  }

  /// Consumes the next value, requiring [expectedTag] unless it is null.
  DerValue read(int? expectedTag, String context) {
    if (_offset >= _end) {
      throw FormatException('$context is missing');
    }
    final start = _offset;
    final tag = _bytes[_offset++];
    if (tag & 0x1f == 0x1f) {
      throw FormatException('$context uses unsupported high-tag-number form');
    }
    if (_offset >= _end) throw FormatException('$context has no DER length');
    final firstLength = _bytes[_offset++];
    int length;
    if (firstLength == 0x80) {
      throw FormatException('$context uses indefinite-length encoding');
    }
    if (firstLength & 0x80 == 0) {
      length = firstLength;
    } else {
      final count = firstLength & 0x7f;
      if (count == 0 || count > 4 || _offset + count > _end) {
        throw FormatException('$context has an invalid DER length');
      }
      if (_bytes[_offset] == 0) {
        throw FormatException('$context has a non-canonical DER length');
      }
      length = 0;
      for (var index = 0; index < count; index++) {
        length = (length << 8) | _bytes[_offset++];
      }
      if (length < 128) {
        throw FormatException('$context has a non-canonical DER length');
      }
    }
    if (length > _end - _offset) {
      throw FormatException('$context exceeds its DER container');
    }
    final valueStart = _offset;
    _offset += length;
    if (expectedTag != null && tag != expectedTag) {
      throw FormatException(
        '$context has tag 0x${tag.toRadixString(16)}, expected '
        '0x${expectedTag.toRadixString(16)}',
      );
    }
    return DerValue(
      bytes: _bytes,
      start: start,
      valueStart: valueStart,
      end: _offset,
      tag: tag,
    );
  }

  void requireDone(String context) {
    if (!isDone) throw FormatException('$context has trailing DER data');
  }
}

/// A parsed DER value, kept as views into the original buffer so that
/// [encoded] can be re-emitted byte for byte.
@internal
@immutable
class DerValue {
  const DerValue({
    required this.bytes,
    required this.start,
    required this.valueStart,
    required this.end,
    required this.tag,
  });

  final Uint8List bytes;
  final int start;
  final int valueStart;
  final int end;
  final int tag;

  /// The full tag-length-value encoding.
  Uint8List get encoded => Uint8List.sublistView(bytes, start, end);

  /// The value octets only, without the tag and length.
  Uint8List get value => Uint8List.sublistView(bytes, valueStart, end);

  DerReader reader() => DerReader(bytes, valueStart, end);
}
