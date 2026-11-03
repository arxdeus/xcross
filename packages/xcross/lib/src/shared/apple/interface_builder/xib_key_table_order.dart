import 'package:meta/meta.dart';

/// The order in which `UINibEncoder` writes its key table.
///
/// The encoder collects keys in an `NSMutableDictionary` as it first meets
/// them and writes the table by enumerating that dictionary, so the order
/// is the bucket order of `__NSDictionaryM`: linear probing over a prime
/// sized table, indexed by `CFHash` of the key, growing through
/// `__NSDictionarySizes` when the count passes one more than the matching
/// entry of `__NSDictionaryCapacities` (both read from CoreFoundation).
@internal
final class XibKeyTableOrder {
  const XibKeyTableOrder._();

  static const _sizes = [
    0, 3, 7, 13, 23, 41, 71, 127, 191, 251, 383, 631, 1087, 1723, 2803, 4523, //
  ];
  static const _capacities = [
    0, 3, 6, 11, 19, 32, 52, 85, 118, 155, 237, 390, 672, 1065, 1732, 2795, //
  ];

  /// [keys] in first use order, rearranged into dictionary bucket order.
  static List<String> order(List<String> keys) {
    if (keys.length > _capacities.last) {
      throw UnsupportedError('${keys.length} archive keys');
    }
    final hashes = <String, BigInt>{for (final k in keys) k: cfHash(k)};
    var level = 1;
    var table = List<String?>.filled(_sizes[level], null);
    void place(List<String?> t, String k) {
      final size = BigInt.from(t.length);
      var i = (hashes[k]! % size).toInt();
      while (t[i] != null) {
        i = (i + 1) % t.length;
      }
      t[i] = k;
    }

    var count = 0;
    for (final k in keys) {
      place(table, k);
      count++;
      // The encoder's table grows one insertion later than a plain
      // dictionary would (checked against 351 ibtool archives).
      if (count > _capacities[level] + 1 || count >= table.length) {
        level++;
        final grown = List<String?>.filled(_sizes[level], null);
        for (final x in table) {
          if (x != null) place(grown, x);
        }
        table = grown;
      }
    }
    return [for (final k in table) ?k];
  }

  static final _mask = (BigInt.one << 64) - BigInt.one;

  /// `CFHash` of a `CFString` (`__CFStrHashCharacters`), as an unsigned 64
  /// bit value.
  static BigInt cfHash(String s) {
    var chars = s.codeUnits;
    final n = chars.length;
    if (n > 96) {
      chars = [
        ...chars.sublist(0, 32),
        ...chars.sublist(n ~/ 2 - 16, n ~/ 2 + 16),
        ...chars.sublist(n - 32),
      ];
    }
    var r = BigInt.from(n);
    var i = 0;
    while (i + 4 <= chars.length) {
      r =
          (r * BigInt.from(67503105) +
              BigInt.from(chars[i] * 16974593) +
              BigInt.from(chars[i + 1] * 66049) +
              BigInt.from(chars[i + 2] * 257) +
              BigInt.from(chars[i + 3])) &
          _mask;
      i += 4;
    }
    while (i < chars.length) {
      r = (r * BigInt.from(257) + BigInt.from(chars[i])) & _mask;
      i++;
    }
    return (r + (r << (n & 31))) & _mask;
  }
}
