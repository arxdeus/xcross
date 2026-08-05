import 'dart:convert';
import 'dart:typed_data';

import 'package:propertylistserialization/propertylistserialization.dart';

/// Binary property lists open with this 8-byte magic; anything else is XML.
const String binaryPlistMagic = 'bplist00';

/// Decodes either property-list flavour.
///
/// Throws when [bytes] is neither, which every caller turns into its own
/// path-qualified error.
Object decodePropertyList(Uint8List bytes) =>
    bytes.length >= 8 && ascii.decode(bytes.sublist(0, 8)) == binaryPlistMagic
    ? PropertyListSerialization.propertyListWithData(
        ByteData.sublistView(bytes),
      )
    : PropertyListSerialization.propertyListWithString(utf8.decode(bytes));
