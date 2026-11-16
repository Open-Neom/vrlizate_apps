import 'dart:typed_data';

import 'package:vrlizate_world/vrlizate_world.dart' show VrlwByteSource;

import 'vrlz_stream_source.dart';

Future<VrlzRandomAccessSource> openFileRandomAccessSource(String path) {
  throw UnsupportedError(
    'Filesystem VRLZ random-access streaming is unavailable on Web.',
  );
}

Future<VrlzRandomAccessSource> openFdSpecRandomAccessSource(String spec) {
  throw UnsupportedError(
    'POSIX fd:<n> VRLZ streaming is unavailable on Web.',
  );
}

Future<VrlzRandomAccessSource> openPosixFdRandomAccessSource(
  int fd, {
  String displayName = 'archive.vrlz',
}) {
  throw UnsupportedError(
    'POSIX fd:<n> VRLZ streaming is unavailable on Web.',
  );
}

Future<VrlzRandomAccessSource> openAndroidSafUriRandomAccessSource(
  String contentUri, {
  String displayName = 'archive.vrlz',
}) {
  throw UnsupportedError(
    'Android SAF JNI VRLZ streaming is unavailable on Web.',
  );
}

VrlzTempBufferSink createTempBufferSink({required int expectedLength}) =>
    _MemoryTempBufferSink(expectedLength);

final class _MemoryTempBufferSink implements VrlzTempBufferSink {
  _MemoryTempBufferSink(int expectedLength)
    : _buffer = Uint8List(expectedLength);

  final Uint8List _buffer;
  int _offset = 0;
  bool _done = false;

  @override
  void addSlice(Uint8List chunk, int start, int end) {
    if (_done) throw StateError('Temp buffer sink already closed.');
    final count = end - start;
    if (count < 0 || _offset + count > _buffer.length) {
      throw const FormatException('Temp buffer exceeded expected byte length.');
    }
    _buffer.setRange(_offset, _offset + count, chunk, start);
    _offset += count;
  }

  @override
  VrlzTempBuffer finish() {
    if (_done) throw StateError('Temp buffer sink already closed.');
    _done = true;
    if (_offset != _buffer.length) {
      throw const FormatException('Temp buffer length mismatch.');
    }
    return _MemoryTempBuffer(_buffer);
  }

  @override
  void abort() {
    _done = true;
  }
}

final class _MemoryTempBuffer implements VrlzTempBuffer {
  _MemoryTempBuffer(this._bytes);

  final Uint8List _bytes;
  bool _closed = false;

  @override
  int get length => _bytes.length;

  @override
  bool get isFileBacked => false;

  @override
  bool get isMemoryMapped => false;

  @override
  bool get isClosed => _closed;

  @override
  Uint8List readBytesSync(int offset, int length) {
    if (_closed) throw StateError('Temp buffer is closed.');
    if (offset < 0 ||
        length < 0 ||
        length > VrlwByteSource.maxReadLength ||
        offset > _bytes.length - length) {
      throw RangeError('Temp buffer range out of bounds.');
    }
    return Uint8List.fromList(
      Uint8List.sublistView(_bytes, offset, offset + length),
    );
  }

  @override
  Future<Uint8List> readRange(int offset, int length) async =>
      readBytesSync(offset, length);

  @override
  Future<void> close() async {
    _closed = true;
  }
}
