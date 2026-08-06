import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:darwin_sdk_kit/src/errors.dart';
import 'package:xml/xml.dart';

/// `xar!` magic, big-endian u32, from the start of every XAR file.
const int _xarMagic = 0x7861_7221;

/// Fixed prefix of the XAR header we read: `magic(4) headerSize(2)
/// version(2) tocLengthCompressed(8) tocLengthUncompressed(8) cksumAlg(4)`.
const int _headerPrefixSize = 28;

const int _headerSizeOffset = 4;
const int _tocLengthCompressedOffset = 8;

/// Absolute byte range of a single named entry's data in a XAR archive's
/// heap.
final class XarEntry {
  const XarEntry({required this.offset, required this.length});

  /// Absolute offset, from the start of the file, of the entry's data.
  final int offset;

  /// Length in bytes of the entry's data as stored in the heap.
  final int length;
}

/// Locates named entries in a XAR table of contents.
abstract final class XarReader {
  /// Locates the `<file><name>[name]</name>` entry in [file]'s XAR table of
  /// contents and returns its absolute heap byte range, or null if no such
  /// entry exists. Not a general-purpose XAR reader.
  static Future<XarEntry?> findEntry(RandomAccessFile file, String name) async {
    await file.setPosition(0);
    final header = ByteData.sublistView(await file.read(_headerPrefixSize));
    if (header.getUint32(0) != _xarMagic) {
      throw DarwinSdkError('Not a XAR file (bad magic).');
    }
    final tocStart = header.getUint16(_headerSizeOffset);
    final tocLengthCompressed = header.getUint64(_tocLengthCompressedOffset);

    await file.setPosition(tocStart);
    final tocCompressed = await file.read(tocLengthCompressed);
    final tocXml = utf8.decode(ZLibDecoder().convert(tocCompressed));
    final document = XmlDocument.parse(tocXml);

    final heapStart = tocStart + tocLengthCompressed;
    for (final fileElement in document.findAllElements('file')) {
      if (fileElement.getElement('name')?.innerText != name) continue;
      final data = fileElement.getElement('data');
      if (data == null) continue;
      final offset = int.parse(data.getElement('offset')!.innerText.trim());
      final length = int.parse(data.getElement('length')!.innerText.trim());
      return XarEntry(offset: heapStart + offset, length: length);
    }
    return null;
  }
}
