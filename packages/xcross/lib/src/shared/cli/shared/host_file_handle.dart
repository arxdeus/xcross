import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:meta/meta.dart';

/// An archive file handle over a [RandomAccessFile] opened through a host
/// file system, so archive streams honour its path mapping (a selected
/// namespace, the Windows `\\?\` long-path spelling) instead of opening the
/// logical path with `dart:io` directly.
@internal
final class HostRandomAccessFileHandle extends AbstractFileHandle {
  HostRandomAccessFileHandle(RandomAccessFile file)
    : _file = file,
      _length = file.lengthSync();

  /// Opens [file] for reading.
  factory HostRandomAccessFileHandle.read(File file) =>
      HostRandomAccessFileHandle(file.openSync());

  /// Creates (or truncates) [file] and opens it for writing.
  factory HostRandomAccessFileHandle.write(File file) {
    file.createSync(recursive: true);
    return HostRandomAccessFileHandle(file.openSync(mode: FileMode.write));
  }

  RandomAccessFile? _file;
  int _position = 0;
  int _length;

  @override
  int get position => _position;

  @override
  set position(int value) {
    final file = _file;
    if (file == null || value == _position) return;
    _position = value;
    file.setPositionSync(value);
  }

  @override
  int get length => _length;

  @override
  bool get isOpen => _file != null;

  @override
  bool open({FileAccess mode = FileAccess.read}) => _file != null;

  @override
  Future<void> close() async {
    final file = _file;
    if (file == null) return;
    _file = null;
    _position = 0;
    await file.close();
  }

  @override
  void closeSync() {
    final file = _file;
    if (file == null) return;
    _file = null;
    _position = 0;
    file.closeSync();
  }

  @override
  int readInto(Uint8List buffer, [int? length]) {
    final size = _file!.readIntoSync(buffer, 0, length);
    _position += size;
    return size;
  }

  @override
  void writeFromSync(List<int> buffer, [int start = 0, int? end]) {
    _file!.writeFromSync(buffer, start, end);
    final written = (end ?? buffer.length) - start;
    _position += written;
    if (_position > _length) _length = _position;
  }
}
