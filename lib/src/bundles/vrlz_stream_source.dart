import 'dart:typed_data';

import 'package:vrlizate_world/vrlizate_world.dart' show VrlwByteSource;

import 'vrlz_stream_source_stub.dart'
    if (dart.library.io) 'vrlz_stream_source_io.dart'
    as backend;

/// Parsed Android SAF / launcher file-descriptor specification `fd:<n>/<name>`.
///
/// Mirrors the permissive (`MIT`) `nup_fd_spec` zero-copy contract so Android
/// `ContentResolver.openFileDescriptor(uri, "r")` descriptors can be read via
/// `pread` without copying multi-world `.vrlz` archives into app sandbox disk.
final class VrlzFdSpec {
  const VrlzFdSpec({required this.fd, required this.displayName});

  final int fd;
  final String displayName;

  String get canonicalSpec => 'fd:$fd/$displayName';

  static bool isFdSpec(String value) => value.startsWith('fd:');

  /// Parses `"fd:<n>"` or `"fd:<n>/<displayName>"` with strict validation.
  static VrlzFdSpec parse(String raw) {
    final parsed = tryParse(raw);
    if (parsed == null) {
      throw FormatException('Invalid VRLZ fd spec: "$raw".');
    }
    return parsed;
  }

  static VrlzFdSpec? tryParse(String raw) {
    if (!raw.startsWith('fd:') || raw.length > 512) return null;
    final body = raw.substring(3);
    if (body.isEmpty) return null;
    final slash = body.indexOf('/');
    final fdText = slash < 0 ? body : body.substring(0, slash);
    if (!RegExp(r'^[0-9]{1,10}$').hasMatch(fdText)) return null;
    final fd = int.tryParse(fdText);
    if (fd == null || fd < 0 || fd > 0x7fffffff) return null;

    var name = 'archive.vrlz';
    if (slash >= 0) {
      final tail = body.substring(slash + 1).trim();
      if (tail.isNotEmpty) {
        // Keep only the terminal basename and strip unsafe characters.
        final parts = tail
            .replaceAll('\\', '/')
            .split('/')
            .where((s) => s.isNotEmpty && s != '.' && s != '..')
            .toList();
        if (parts.isEmpty) return null;
        final candidate = parts.last.replaceAll(
          RegExp(r'[\x00-\x1F\x7F]'),
          '_',
        );
        if (candidate.isNotEmpty && candidate.length <= 180) {
          name = candidate;
        }
      }
    }
    return VrlzFdSpec(fd: fd, displayName: name);
  }
}

/// Stateless random-access byte source for `.vrlz` archives without full-file
/// heap allocation or directory extraction.
abstract interface class VrlzRandomAccessSource {
  int get length;
  String get displayName;
  bool get isClosed;

  /// Reads exactly [length] bytes starting at [offset].
  Future<Uint8List> readRange(int offset, int length);

  Future<void> close();

  /// Wraps an in-memory buffer as a [VrlzRandomAccessSource].
  factory VrlzRandomAccessSource.memory(
    Uint8List bytes, {
    String displayName,
    bool copy,
  }) = VrlzMemoryRandomAccessSource;

  /// Opens a local filesystem path for random-access `pread` / `RandomAccessFile`.
  static Future<VrlzRandomAccessSource> openFilePath(String path) =>
      backend.openFileRandomAccessSource(path);

  /// Opens an `fd:<n>/<name>` specification by duplicating the descriptor with
  /// `F_DUPFD_CLOEXEC` so closing this source leaves the caller's fd intact.
  static Future<VrlzRandomAccessSource> openFdSpec(String spec) =>
      backend.openFdSpecRandomAccessSource(spec);

  /// Opens a raw POSIX file descriptor by duplicating it with `F_DUPFD_CLOEXEC`.
  static Future<VrlzRandomAccessSource> openPosixFd(
    int fd, {
    String displayName = 'archive.vrlz',
  }) => backend.openPosixFdRandomAccessSource(fd, displayName: displayName);

  /// Opens an Android Storage Access Framework (`content://`) URI directly via
  /// native JNI (`ContentResolver.openFileDescriptor` -> `detachFd` -> `pread`)
  /// with zero host Kotlin `MethodChannel` boilerplate and zero disk unpacking.
  static Future<VrlzRandomAccessSource> openAndroidSafUri(
    String contentUri, {
    String displayName = 'archive.vrlz',
  }) => backend.openAndroidSafUriRandomAccessSource(
    contentUri,
    displayName: displayName,
  );
}

/// Read-only random-access buffer backed either by an unlinked temporary file
/// mapped with POSIX `mmap(PROT_READ, MAP_PRIVATE)` on native platforms or by
/// an in-memory fallback on Web.
abstract interface class VrlzTempBuffer implements VrlwByteSource {
  @override
  int get length;

  /// Whether this buffer is backed by an OS file/mmap page-cache mapping rather
  /// than the Dart GC heap.
  bool get isFileBacked;

  /// Whether POSIX `mmap` is active for this buffer.
  bool get isMemoryMapped;

  bool get isClosed;

  Uint8List readBytesSync(int offset, int length);

  @override
  Future<Uint8List> readRange(int offset, int length);

  @override
  Future<void> close();
}

/// Streaming writer that builds a [VrlzTempBuffer] without holding the full
/// unpacked payload on the Dart heap.
abstract interface class VrlzTempBufferSink {
  void addSlice(Uint8List chunk, int start, int end);
  VrlzTempBuffer finish();
  void abort();

  factory VrlzTempBufferSink.open({required int expectedLength}) =>
      backend.createTempBufferSink(expectedLength: expectedLength);
}

/// In-memory [VrlzRandomAccessSource] for tests, Web buffers, and small assets.
final class VrlzMemoryRandomAccessSource implements VrlzRandomAccessSource {
  VrlzMemoryRandomAccessSource(
    Uint8List bytes, {
    this.displayName = 'memory.vrlz',
    bool copy = false,
  }) : _bytes = copy ? Uint8List.fromList(bytes) : bytes;

  final Uint8List _bytes;
  bool _closed = false;

  @override
  final String displayName;

  @override
  int get length => _bytes.length;

  @override
  bool get isClosed => _closed;

  @override
  Future<Uint8List> readRange(int offset, int length) async {
    if (_closed) {
      throw StateError('VRLZ memory source is closed.');
    }
    if (offset < 0 || length < 0 || offset > _bytes.length - length) {
      throw RangeError(
        'VRLZ range [$offset..${offset + length}) exceeds ${_bytes.length}.',
      );
    }
    if (length == 0) return Uint8List(0);
    return Uint8List.fromList(
      Uint8List.sublistView(_bytes, offset, offset + length),
    );
  }

  @override
  Future<void> close() async {
    _closed = true;
  }
}
