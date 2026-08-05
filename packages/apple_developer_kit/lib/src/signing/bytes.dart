import 'dart:convert';

/// Orders two byte strings lexicographically, shorter-is-smaller on a tie.
///
/// Apple's signing formats are full of length-prefixed byte comparisons that
/// must not follow Dart's UTF-16 [String.compareTo]: DER `SET OF` members are
/// sorted by their encoding, and both entitlement plist keys and CodeResources
/// seal keys are sorted by their UTF-8 bytes.
int compareBytes(List<int> left, List<int> right) {
  final shared = left.length < right.length ? left.length : right.length;
  for (var index = 0; index < shared; index++) {
    final order = left[index].compareTo(right[index]);
    if (order != 0) return order;
  }
  return left.length.compareTo(right.length);
}

/// Orders two strings by their UTF-8 encodings via [compareBytes].
int compareUtf8(String left, String right) =>
    compareBytes(utf8.encode(left), utf8.encode(right));
