import 'dart:typed_data';

import 'package:meta/meta.dart';

/// A decoded PEM block: its `BEGIN`/`END` [label] and the base64-decoded body.
@immutable
final class PemBlock {
  const PemBlock({required this.label, required this.bytes});

  final String label;
  final Uint8List bytes;
}
