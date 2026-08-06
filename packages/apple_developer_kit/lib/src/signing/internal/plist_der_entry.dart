import 'dart:typed_data';

import 'package:meta/meta.dart';

/// A plist dictionary entry staged for DER encoding, keyed by its UTF-8
/// encoded name so entries can be sorted bytewise.
@immutable
final class PlistDerEntry {
  const PlistDerEntry({required this.key, required this.value});

  final Uint8List key;
  final Object? value;
}
