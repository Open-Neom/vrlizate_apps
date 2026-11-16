import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart'
    show ByteOrder, Inflate, InputMemoryStream, InputStream, OutputStream, getCrc32;
import 'package:vrlizate_world/vrlizate_world.dart' show VrlwByteSource;

import 'vrlz_stream_source.dart';

/// Metadata parsed from the `.vrlz` ZIP Central Directory without reading
/// entry payloads into memory.
final class VrlzArchiveEntryInfo {
  const VrlzArchiveEntryInfo({
    required this.name,
    required this.compressionMethod,
    required this.crc32,
    required this.packedBytes,
    required this.unpackedBytes,
    required this.localHeaderOffset,
    required this.versionNeeded,
    required this.flags,
  });

  static const int methodStore = 0;
  static const int methodDeflate = 8;

  final String name;
  final int compressionMethod;
  final int crc32;
  final int packedBytes;
  final int unpackedBytes;
  final int localHeaderOffset;
  final int versionNeeded;
  final int flags;

  bool get isStored => compressionMethod == methodStore;
  bool get isDeflated => compressionMethod == methodDeflate;
}

/// Zero-unpack random-access `.vrlz` archive reader inspired by the permissive
/// (`MIT`) `nup` container design:
/// - Reads ONLY the EOCD + Central Directory on [open] (O(1) RAM regardless of
///   total archive size or world count).
/// - Streams `STORE` (`method == 0`) slices directly via `pread` / `readRange`
///   without extracting files or duplicating world payloads on heap.
/// - Caches small entries in a byte-budgeted LRU (`maxMemoryCacheBytes`) with
///   concurrent in-flight request coalescing.
/// - Spills large entries (`>= tempFileThresholdBytes`) and large `DEFLATE`
///   streams into [VrlzTempBuffer] (unlinked temp file + POSIX `mmap`
///   `PROT_READ | MAP_PRIVATE` on native OSes) so clean pages stay evictable
///   instead of pressuring Android `zram` / `lmkd`.
final class VrlzStreamArchive {
  VrlzStreamArchive._({
    required this.source,
    required this.ownsSource,
    required Map<String, VrlzArchiveEntryInfo> entries,
    required this.centralDirectoryOffset,
    required this.maxMemoryCacheBytes,
    required this.tempFileThresholdBytes,
  }) : _entries = entries;

  static const int defaultMaxArchiveBytes = 256 * 1024 * 1024;
  static const int defaultMaxEntries = 256;
  static const int defaultMaxMemoryCacheBytes = 16 * 1024 * 1024;
  static const int defaultTempFileThresholdBytes = 8 * 1024 * 1024;

  final VrlzRandomAccessSource source;
  final bool ownsSource;
  final int centralDirectoryOffset;
  final int maxMemoryCacheBytes;
  final int tempFileThresholdBytes;
  final Map<String, VrlzArchiveEntryInfo> _entries;

  final LinkedHashMap<String, Uint8List> _lru =
      LinkedHashMap<String, Uint8List>();
  final Map<String, VrlzTempBuffer> _spilled = <String, VrlzTempBuffer>{};
  final Map<String, Future<Uint8List>> _inflightBytes =
      <String, Future<Uint8List>>{};
  final Map<String, Future<VrlzTempBuffer>> _inflightSpill =
      <String, Future<VrlzTempBuffer>>{};
  final Map<String, int> _verifiedDataOffsets = <String, int>{};

  int _cachedMemoryBytes = 0;
  bool _closed = false;

  bool get isClosed => _closed;
  int get cachedMemoryBytes => _cachedMemoryBytes;
  int get spilledEntryCount => _spilled.length;
  Iterable<String> get fileNames => _entries.keys;
  Map<String, VrlzArchiveEntryInfo> get entries => Map.unmodifiable(_entries);

  VrlzArchiveEntryInfo? entry(String name) => _entries[name];
  bool containsFile(String name) => _entries.containsKey(name);

  /// Parses and validates the `.vrlz` EOCD + Central Directory via bounded
  /// tail reads without reading any entry payloads.
  static Future<VrlzStreamArchive> open(
    VrlzRandomAccessSource source, {
    bool ownsSource = true,
    int maxArchiveBytes = defaultMaxArchiveBytes,
    int maxEntries = defaultMaxEntries,
    int maxEntryUnpackedBytes = 64 * 1024 * 1024,
    int maxTotalUnpackedBytes = 256 * 1024 * 1024,
    bool allowDeflate = true,
    bool allowManifestOnly = false,
    Set<String>? allowedFiles,
    bool Function(String)? allowAdditionalFile,
    int maxManifestBytes = 65536,
    int maxMemoryCacheBytes = defaultMaxMemoryCacheBytes,
    int tempFileThresholdBytes = defaultTempFileThresholdBytes,
  }) async {
    try {
      final totalLen = source.length;
      if (totalLen < 22 || totalLen > maxArchiveBytes) {
        throw const FormatException(
          'VRLZ stream archive exceeds its size budget or is truncated.',
        );
      }
      if (maxEntries < 1 ||
          maxEntries > 65535 ||
          maxMemoryCacheBytes < 0 ||
          tempFileThresholdBytes < 0) {
        throw ArgumentError('Invalid VRLZ stream archive limits.');
      }

      // Read up to the maximum possible EOCD + comment window (22 + 65535).
      final tailLen = math.min(totalLen, 22 + 65535);
      final tailOffset = totalLen - tailLen;
      final tail = await source.readRange(tailOffset, tailLen);
      final tailData = ByteData.sublistView(tail);

      int? eocdRel;
      for (var pos = tail.length - 22; pos >= 0; pos--) {
        if (tailData.getUint32(pos, Endian.little) == 0x06054b50) {
          final commentLen = tailData.getUint16(pos + 20, Endian.little);
          if (pos + 22 + commentLen == tail.length) {
            eocdRel = pos;
            break;
          }
        }
      }
      if (eocdRel == null) {
        throw const FormatException('Missing or invalid ZIP EOCD signature.');
      }

      final diskNo = tailData.getUint16(eocdRel + 4, Endian.little);
      final cdDisk = tailData.getUint16(eocdRel + 6, Endian.little);
      final diskEntries = tailData.getUint16(eocdRel + 8, Endian.little);
      final entryCount = tailData.getUint16(eocdRel + 10, Endian.little);
      final centralSize = tailData.getUint32(eocdRel + 12, Endian.little);
      final centralStart = tailData.getUint32(eocdRel + 16, Endian.little);
      final eocdAbs = tailOffset + eocdRel;

      if (diskNo != 0 ||
          cdDisk != 0 ||
          diskEntries != entryCount ||
          entryCount < (allowManifestOnly ? 1 : 2) ||
          entryCount > maxEntries ||
          centralStart > eocdAbs ||
          centralSize > eocdAbs - centralStart ||
          centralStart + centralSize != eocdAbs) {
        throw const FormatException(
          'VRLZ requires a single-disk ZIP with contiguous central directory.',
        );
      }

      final cdBytes = await source.readRange(centralStart, centralSize);
      final cdData = ByteData.sublistView(cdBytes);

      void checkCdRange(int at, int len) {
        if (at < 0 || len < 0 || at > cdBytes.length - len) {
          throw const FormatException('Truncated ZIP central directory.');
        }
      }

      int cdU16(int at) {
        checkCdRange(at, 2);
        return cdData.getUint16(at, Endian.little);
      }

      int cdU32(int at) {
        checkCdRange(at, 4);
        return cdData.getUint32(at, Endian.little);
      }

      var cursor = 0;
      var totalUnpacked = 0;
      final parsedEntries = <String, VrlzArchiveEntryInfo>{};

      for (var i = 0; i < entryCount; i++) {
        checkCdRange(cursor, 46);
        if (cdU32(cursor) != 0x02014b50) {
          throw const FormatException('Invalid ZIP central file header.');
        }
        final versionNeeded = cdU16(cursor + 6);
        final flags = cdU16(cursor + 8);
        final method = cdU16(cursor + 10);
        final crc = cdU32(cursor + 16);
        final packed = cdU32(cursor + 20);
        final unpacked = cdU32(cursor + 24);
        final nameLen = cdU16(cursor + 28);
        final extraLen = cdU16(cursor + 30);
        final commentLen = cdU16(cursor + 32);
        final diskStart = cdU16(cursor + 34);
        final extAttrs = cdU32(cursor + 38);
        final localOffset = cdU32(cursor + 42);
        final unixModeType = (extAttrs >> 16) & 0xf000;

        // Disallow encryption (bit 0), streaming data descriptors (bit 3),
        // symlinks/directories, ZIP64 sentinel sizes, or unsupported codecs.
        final validMethod =
            method == VrlzArchiveEntryInfo.methodStore ||
            (allowDeflate && method == VrlzArchiveEntryInfo.methodDeflate);
        if (versionNeeded > 20 ||
            (flags & ~0x0800) != 0 ||
            !validMethod ||
            (method == VrlzArchiveEntryInfo.methodStore &&
                packed != unpacked) ||
            packed == 0xffffffff ||
            unpacked == 0xffffffff ||
            localOffset == 0xffffffff ||
            packed > maxArchiveBytes ||
            unpacked > maxEntryUnpackedBytes ||
            diskStart != 0 ||
            (extAttrs & 0x10) != 0 ||
            (unixModeType != 0 && unixModeType != 0x8000)) {
          throw const FormatException(
            'Unsupported or unsafe ZIP entry method, flags, or attributes.',
          );
        }

        totalUnpacked += unpacked;
        if (totalUnpacked > maxTotalUnpackedBytes) {
          throw const FormatException(
            'VRLZ archive exceeds its total unpacked byte budget.',
          );
        }

        checkCdRange(cursor + 46, nameLen + extraLen + commentLen);
        final filename = utf8.decode(
          Uint8List.sublistView(cdBytes, cursor + 46, cursor + 46 + nameLen),
        );
        if (!_isSafeEntryPath(filename) ||
            parsedEntries.containsKey(filename)) {
          throw const FormatException('Unsafe or duplicate ZIP entry name.');
        }
        if (allowedFiles != null &&
            !allowedFiles.contains(filename) &&
            !(allowAdditionalFile?.call(filename) ?? false)) {
          throw const FormatException('Undeclared file in VRLZ archive.');
        }
        if (filename == 'manifest.json' && unpacked > maxManifestBytes) {
          throw const FormatException('Manifest exceeds its metadata budget.');
        }
        if (localOffset + 30 + nameLen + packed > centralStart) {
          throw const FormatException(
            'ZIP entry overlaps central directory.',
          );
        }

        parsedEntries[filename] = VrlzArchiveEntryInfo(
          name: filename,
          compressionMethod: method,
          crc32: crc,
          packedBytes: packed,
          unpackedBytes: unpacked,
          localHeaderOffset: localOffset,
          versionNeeded: versionNeeded,
          flags: flags,
        );
        cursor += 46 + nameLen + extraLen + commentLen;
      }

      if (cursor != cdBytes.length ||
          parsedEntries.length != entryCount ||
          !parsedEntries.containsKey('manifest.json')) {
        throw const FormatException(
          'VRLZ central directory is incomplete or lacks manifest.json.',
        );
      }

      return VrlzStreamArchive._(
        source: source,
        ownsSource: ownsSource,
        entries: parsedEntries,
        centralDirectoryOffset: centralStart,
        maxMemoryCacheBytes: maxMemoryCacheBytes,
        tempFileThresholdBytes: tempFileThresholdBytes,
      );
    } catch (_) {
      if (ownsSource) {
        await source.close();
      }
      rethrow;
    }
  }

  static bool _isSafeEntryPath(String path) {
    if (path.isEmpty ||
        path.length > 255 ||
        path.startsWith('/') ||
        path.endsWith('/') ||
        path.contains('\\') ||
        RegExp(r'[\x00-\x1F\x7F]').hasMatch(path)) {
      return false;
    }
    final segments = path.split('/');
    for (final seg in segments) {
      if (seg.isEmpty || seg == '.' || seg == '..') return false;
    }
    return true;
  }

  void _checkOpen() {
    if (_closed) throw StateError('VRLZ stream archive is closed.');
  }

  VrlzArchiveEntryInfo _requireEntry(String name) {
    _checkOpen();
    final info = _entries[name];
    if (info == null) {
      throw FormatException('Missing VRLZ entry "$name".');
    }
    return info;
  }

  /// Verifies the local header for [info] once and returns the payload offset.
  Future<int> _resolvePayloadOffset(VrlzArchiveEntryInfo info) async {
    final cached = _verifiedDataOffsets[info.name];
    if (cached != null) return cached;

    final nameBytes = utf8.encode(info.name);
    final fixed = await source.readRange(info.localHeaderOffset, 30);
    final header = ByteData.sublistView(fixed);
    if (header.getUint32(0, Endian.little) != 0x04034b50) {
      throw const FormatException('Invalid ZIP local file header signature.');
    }
    final localVersion = header.getUint16(4, Endian.little);
    final localFlags = header.getUint16(6, Endian.little);
    final localMethod = header.getUint16(8, Endian.little);
    final localCrc = header.getUint32(14, Endian.little);
    final localPacked = header.getUint32(18, Endian.little);
    final localUnpacked = header.getUint32(22, Endian.little);
    final localNameLen = header.getUint16(26, Endian.little);
    final localExtraLen = header.getUint16(28, Endian.little);

    if (localVersion != info.versionNeeded ||
        localFlags != info.flags ||
        localMethod != info.compressionMethod ||
        localCrc != info.crc32 ||
        localPacked != info.packedBytes ||
        localUnpacked != info.unpackedBytes ||
        localNameLen != nameBytes.length) {
      throw const FormatException(
        'ZIP local header disagrees with central directory.',
      );
    }

    final localName = await source.readRange(
      info.localHeaderOffset + 30,
      localNameLen,
    );
    if (utf8.decode(localName) != info.name) {
      throw const FormatException('ZIP local filename mismatch.');
    }

    final dataStart = info.localHeaderOffset + 30 + localNameLen + localExtraLen;
    if (dataStart + info.packedBytes > centralDirectoryOffset) {
      throw const FormatException(
        'ZIP entry payload overlaps central directory.',
      );
    }
    _verifiedDataOffsets[info.name] = dataStart;
    return dataStart;
  }

  /// Reads and CRC-32-verifies [name].
  ///
  /// - Entries `< tempFileThresholdBytes` are cached in the bounded LRU (with
  ///   concurrent request coalescing).
  /// - Entries `>= tempFileThresholdBytes` spill to [VrlzTempBuffer] (`mmap` on
  ///   native OSes) so repeated reads page from clean OS file cache without
  ///   pinning multi-megabyte buffers in the Dart GC heap.
  Future<Uint8List> readEntryBytes(String name) async {
    final info = _requireEntry(name);

    // 1. Check LRU memory cache (promote to MRU on hit).
    final hit = _lru.remove(name);
    if (hit != null) {
      _lru[name] = hit;
      return Uint8List.fromList(hit);
    }

    // 2. Check spilled temp/mmap buffer cache.
    final spilled = _spilled[name];
    if (spilled != null && !spilled.isClosed) {
      return spilled.readRange(0, spilled.length);
    }

    // 3. Large entry path -> spill to file-backed mmap buffer first.
    if (info.unpackedBytes >= tempFileThresholdBytes &&
        tempFileThresholdBytes > 0) {
      final buf = await _ensureSpilled(info);
      return buf.readRange(0, buf.length);
    }

    // 4. Coalesce concurrent small-entry reads.
    final pending = _inflightBytes[name];
    if (pending != null) {
      return Uint8List.fromList(await pending);
    }

    final future = _loadSmallEntryUncached(info);
    _inflightBytes[name] = future;
    try {
      final bytes = await future;
      if (!_closed) {
        _insertLru(name, bytes);
      }
      return Uint8List.fromList(bytes);
    } finally {
      _inflightBytes.remove(name);
    }
  }

  void _insertLru(String name, Uint8List bytes) {
    if (bytes.length > maxMemoryCacheBytes || maxMemoryCacheBytes <= 0) {
      return;
    }
    final existing = _lru.remove(name);
    if (existing != null) {
      _cachedMemoryBytes -= existing.length;
    }
    while (_lru.isNotEmpty &&
        _cachedMemoryBytes + bytes.length > maxMemoryCacheBytes) {
      final oldestKey = _lru.keys.first;
      final removed = _lru.remove(oldestKey)!;
      _cachedMemoryBytes -= removed.length;
    }
    _lru[name] = bytes;
    _cachedMemoryBytes += bytes.length;
  }

  Future<Uint8List> _loadSmallEntryUncached(VrlzArchiveEntryInfo info) async {
    final dataOffset = await _resolvePayloadOffset(info);
    final packed = await source.readRange(dataOffset, info.packedBytes);
    _checkOpen();
    final Uint8List unpacked;
    if (info.isStored) {
      unpacked = packed;
    } else {
      unpacked = _inflateBoundedToMemory(packed, info.unpackedBytes);
    }
    if (getCrc32(unpacked) != info.crc32) {
      throw const FormatException('ZIP entry CRC-32 mismatch.');
    }
    return unpacked;
  }

  static Uint8List _inflateBoundedToMemory(
    Uint8List packed,
    int expectedUnpacked,
  ) {
    final padded = Uint8List(packed.length + 6)
      ..setRange(0, packed.length, packed);
    final input = InputMemoryStream(padded);
    final output = _MemoryBoundedInflateOutput(expectedUnpacked);
    try {
      Inflate.stream(input, output: output);
    } catch (_) {
      throw const FormatException('Invalid or over-budget DEFLATE entry.');
    }
    if (input.position != packed.length || output.length != expectedUnpacked) {
      throw const FormatException(
        'DEFLATE entry unpacked size mismatch or trailing data.',
      );
    }
    return output.bytes;
  }

  Future<VrlzTempBuffer> _ensureSpilled(VrlzArchiveEntryInfo info) async {
    final existing = _spilled[info.name];
    if (existing != null && !existing.isClosed) return existing;

    final pending = _inflightSpill[info.name];
    if (pending != null) return pending;

    final future = _spillEntryToTempBuffer(info);
    _inflightSpill[info.name] = future;
    try {
      final buf = await future;
      if (_closed) {
        await buf.close();
        throw StateError('VRLZ stream archive was closed.');
      }
      _spilled[info.name] = buf;
      return buf;
    } finally {
      _inflightSpill.remove(info.name);
    }
  }

  Future<VrlzTempBuffer> _spillEntryToTempBuffer(
    VrlzArchiveEntryInfo info,
  ) async {
    final dataOffset = await _resolvePayloadOffset(info);
    final sink = VrlzTempBufferSink.open(expectedLength: info.unpackedBytes);
    try {
      var crc = 0;
      if (info.isStored) {
        const chunkCap = 256 * 1024;
        var remaining = info.packedBytes;
        var pos = 0;
        while (remaining > 0) {
          final step = math.min(remaining, chunkCap);
          final chunk = await source.readRange(dataOffset + pos, step);
          _checkOpen();
          crc = getCrc32(chunk, crc);
          sink.addSlice(chunk, 0, chunk.length);
          pos += step;
          remaining -= step;
        }
      } else {
        final packed = await source.readRange(dataOffset, info.packedBytes);
        _checkOpen();
        final padded = Uint8List(packed.length + 6)
          ..setRange(0, packed.length, packed);
        final input = InputMemoryStream(padded);
        final streamOut = _SlidingSinkInflateOutput(
          expectedLength: info.unpackedBytes,
          sink: sink,
          onFlushChunk: (chunk, len) {
            crc = getCrc32(Uint8List.sublistView(chunk, 0, len), crc);
          },
        );
        try {
          Inflate.stream(input, output: streamOut);
        } catch (_) {
          throw const FormatException('Invalid or over-budget DEFLATE entry.');
        }
        streamOut.flushRemaining();
        if (input.position != packed.length ||
            streamOut.length != info.unpackedBytes) {
          throw const FormatException(
            'DEFLATE entry unpacked size mismatch or trailing data.',
          );
        }
      }
      if (crc != info.crc32) {
        throw const FormatException('ZIP entry CRC-32 mismatch.');
      }
      return sink.finish();
    } catch (_) {
      sink.abort();
      rethrow;
    }
  }

  /// Opens a random-access [VrlwByteSource] over entry [name]:
  /// - `STORE` entries map directly onto [source] at `[dataOffset .. +length)`
  ///   with **zero copy and zero temporary files**.
  /// - `DEFLATE` entries inflate once into a file-backed `mmap` [VrlzTempBuffer]
  ///   and serve subsequent `.vrlw` chunk range reads from OS page cache.
  Future<VrlwByteSource> openEntryByteSource(
    String name, {
    bool verifyStoreCrcOnOpen = false,
  }) async {
    final info = _requireEntry(name);
    if (info.unpackedBytes > VrlwByteSource.maxLength) {
      throw const FormatException('Entry exceeds VrlwByteSource.maxLength.');
    }
    if (info.isStored) {
      final dataOffset = await _resolvePayloadOffset(info);
      if (verifyStoreCrcOnOpen) {
        await verifyEntryCrc32(name);
      }
      return _ArchiveSliceByteSource(
        archive: this,
        baseOffset: dataOffset,
        byteLength: info.unpackedBytes,
      );
    }
    final spilled = await _ensureSpilled(info);
    return _BorrowedTempBufferByteSource(spilled);
  }

  /// Streams [name] in `256 KiB` blocks to verify its ZIP CRC-32 without
  /// retaining the entry in heap memory.
  Future<void> verifyEntryCrc32(String name) async {
    final info = _requireEntry(name);
    if (!info.isStored) {
      await _ensureSpilled(info);
      return;
    }
    final dataOffset = await _resolvePayloadOffset(info);
    const chunkCap = 256 * 1024;
    var crc = 0;
    var pos = 0;
    var remaining = info.packedBytes;
    while (remaining > 0) {
      final step = math.min(remaining, chunkCap);
      final chunk = await source.readRange(dataOffset + pos, step);
      _checkOpen();
      crc = getCrc32(chunk, crc);
      pos += step;
      remaining -= step;
    }
    if (crc != info.crc32) {
      throw const FormatException('ZIP entry CRC-32 mismatch.');
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _lru.clear();
    _cachedMemoryBytes = 0;
    final buffers = _spilled.values.toList();
    _spilled.clear();
    for (final buf in buffers) {
      await buf.close();
    }
    if (ownsSource) {
      await source.close();
    }
  }
}

final class _ArchiveSliceByteSource implements VrlwByteSource {
  _ArchiveSliceByteSource({
    required this.archive,
    required this.baseOffset,
    required this.byteLength,
  });

  final VrlzStreamArchive archive;
  final int baseOffset;
  final int byteLength;
  bool _closed = false;

  @override
  int get length => byteLength;

  @override
  Future<Uint8List> readRange(int offset, int count) {
    if (_closed || archive.isClosed) {
      throw StateError('VRLZ entry slice is closed.');
    }
    if (offset < 0 ||
        count < 0 ||
        count > VrlwByteSource.maxReadLength ||
        offset > byteLength - count) {
      throw RangeError(
        'VRLZ slice range [$offset..${offset + count}) exceeds $byteLength.',
      );
    }
    return archive.source.readRange(baseOffset + offset, count);
  }

  @override
  Future<void> close() async {
    _closed = true;
  }
}

final class _BorrowedTempBufferByteSource implements VrlwByteSource {
  _BorrowedTempBufferByteSource(this._buffer);

  final VrlzTempBuffer _buffer;
  bool _closed = false;

  @override
  int get length => _buffer.length;

  @override
  Future<Uint8List> readRange(int offset, int count) {
    if (_closed || _buffer.isClosed) {
      throw StateError('Borrowed VRLZ temp buffer slice is closed.');
    }
    return _buffer.readRange(offset, count);
  }

  @override
  Future<void> close() async {
    // Lifecycle belongs to VrlzStreamArchive._spilled.
    _closed = true;
  }
}

final class _MemoryBoundedInflateOutput extends OutputStream {
  _MemoryBoundedInflateOutput(int maxBytes)
    : bytes = Uint8List(maxBytes),
      super(byteOrder: ByteOrder.littleEndian);

  final Uint8List bytes;
  int _length = 0;

  @override
  int get length => _length;

  void _reserve(int count) {
    if (count < 0 || _length + count > bytes.length) {
      throw const FormatException('DEFLATE output exceeds declared size.');
    }
  }

  @override
  void writeByte(int value) {
    _reserve(1);
    bytes[_length++] = value;
  }

  @override
  void writeBytes(List<int> data, {int? length}) {
    final count = length ?? data.length;
    _reserve(count);
    bytes.setRange(_length, _length + count, data);
    _length += count;
  }

  @override
  void writeStream(InputStream stream) {
    final count = stream.length;
    _reserve(count);
    writeBytes(stream.toUint8List(), length: count);
  }

  @override
  Uint8List subset(int start, [int? end]) {
    final first = start < 0 ? _length + start : start;
    final last = end == null ? _length : (end < 0 ? _length + end : end);
    if (first < 0 || last < first || last > _length) {
      throw const FormatException('Invalid DEFLATE back-reference.');
    }
    return Uint8List.sublistView(bytes, first, last);
  }

  @override
  void clear() => _length = 0;

  @override
  void flush() {}
}

/// Constant-memory (`64 KiB` sliding LZ77 window) `OutputStream` that streams
/// `Inflate.stream` output directly into a [VrlzTempBufferSink] while serving
/// RFC 1951 `<= 32 KiB` back-references via [subset].
final class _SlidingSinkInflateOutput extends OutputStream {
  _SlidingSinkInflateOutput({
    required this.expectedLength,
    required this.sink,
    required this.onFlushChunk,
  }) : super(byteOrder: ByteOrder.littleEndian);

  static const int _halfWindow = 32768;
  static const int _windowCapacity = _halfWindow * 2;

  final int expectedLength;
  final VrlzTempBufferSink sink;
  final void Function(Uint8List chunk, int length) onFlushChunk;

  final Uint8List _window = Uint8List(_windowCapacity);
  int _windowBase = 0;
  int _windowLen = 0;
  int _flushedTotal = 0;

  @override
  int get length => _windowBase + _windowLen;

  void _reserve(int count) {
    if (count < 0 || length + count > expectedLength) {
      throw const FormatException('DEFLATE output exceeds declared size.');
    }
  }

  void _spillHalfIfFull() {
    if (_windowLen < _windowCapacity) return;
    // Flush the older 32 KiB half (leaving 32 KiB of LZ77 history in _window).
    final toFlush = _halfWindow;
    sink.addSlice(_window, 0, toFlush);
    onFlushChunk(_window, toFlush);
    _flushedTotal += toFlush;
    _window.setRange(0, _windowLen - toFlush, _window, toFlush);
    _windowBase += toFlush;
    _windowLen -= toFlush;
  }

  @override
  void writeByte(int value) {
    _reserve(1);
    _spillHalfIfFull();
    _window[_windowLen++] = value;
  }

  @override
  void writeBytes(List<int> data, {int? length}) {
    final total = length ?? data.length;
    _reserve(total);
    var offset = 0;
    while (offset < total) {
      _spillHalfIfFull();
      final space = _windowCapacity - _windowLen;
      final step = math.min(space, total - offset);
      for (var i = 0; i < step; i++) {
        _window[_windowLen + i] = data[offset + i];
      }
      _windowLen += step;
      offset += step;
    }
  }

  @override
  void writeStream(InputStream stream) {
    final count = stream.length;
    writeBytes(stream.toUint8List(), length: count);
  }

  @override
  Uint8List subset(int start, [int? end]) {
    final totalLen = length;
    final first = start < 0 ? totalLen + start : start;
    final last = end == null ? totalLen : (end < 0 ? totalLen + end : end);
    if (first < _windowBase || last < first || last > totalLen) {
      throw const FormatException('DEFLATE back-reference exceeds 32 KiB.');
    }
    return Uint8List.sublistView(
      _window,
      first - _windowBase,
      last - _windowBase,
    );
  }

  void flushRemaining() {
    final unflushedStart = _flushedTotal - _windowBase;
    final remaining = _windowLen - unflushedStart;
    if (remaining > 0) {
      final view = Uint8List.sublistView(
        _window,
        unflushedStart,
        unflushedStart + remaining,
      );
      sink.addSlice(view, 0, view.length);
      onFlushChunk(view, view.length);
      _flushedTotal += remaining;
    }
  }

  @override
  void clear() {
    _windowBase = 0;
    _windowLen = 0;
    _flushedTotal = 0;
  }

  @override
  void flush() {}
}
