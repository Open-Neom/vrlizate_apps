import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;

/// Deterministic STORE encoder matching this reader's bounded ZIP subset.
/// No dependency on a ZIP library's descriptor/ZIP64 encoder defaults.
Uint8List writeVrzStoreZip(Map<String, Uint8List> files, int maxBytes) {
  if (files.isEmpty || files.length > 9) {
    throw const FormatException('Invalid STORE archive file count.');
  }
  final local = BytesBuilder(copy: false);
  final central = BytesBuilder(copy: false);
  for (final entry in files.entries) {
    final name = utf8.encode(entry.key);
    final bytes = entry.value;
    final offset = local.length;
    if (name.length > 255 ||
        bytes.length > maxBytes ||
        offset + bytes.length + name.length + 30 > maxBytes) {
      throw const FormatException('STORE archive exceeds its byte budget.');
    }
    final crc = getCrc32(bytes);
    final header = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 0x0800, Endian.little)
      ..setUint16(12, 0x2821, Endian.little)
      ..setUint32(14, crc, Endian.little)
      ..setUint32(18, bytes.length, Endian.little)
      ..setUint32(22, bytes.length, Endian.little)
      ..setUint16(26, name.length, Endian.little);
    local
      ..add(header.buffer.asUint8List())
      ..add(name)
      ..add(bytes);
    final directory = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 20, Endian.little)
      ..setUint16(8, 0x0800, Endian.little)
      ..setUint16(14, 0x2821, Endian.little)
      ..setUint32(16, crc, Endian.little)
      ..setUint32(20, bytes.length, Endian.little)
      ..setUint32(24, bytes.length, Endian.little)
      ..setUint16(28, name.length, Endian.little)
      ..setUint32(42, offset, Endian.little);
    central
      ..add(directory.buffer.asUint8List())
      ..add(name);
  }
  if (local.length + central.length + 22 > maxBytes) {
    throw const FormatException('STORE archive exceeds its byte budget.');
  }
  final end = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, files.length, Endian.little)
    ..setUint16(10, files.length, Endian.little)
    ..setUint32(12, central.length, Endian.little)
    ..setUint32(16, local.length, Endian.little);
  return (BytesBuilder(copy: false)
        ..add(local.takeBytes())
        ..add(central.takeBytes())
        ..add(end.buffer.asUint8List()))
      .takeBytes();
}

/// Exact, bounded STORE-only ZIP reader. No inflation or filesystem extraction.
Map<String, Uint8List> readVrzZip(
  Uint8List bytes,
  int maxBytes, {
  bool allowManifestOnly = false,
  Set<String> allowedFiles = const {'manifest.json', 'scene.glb'},
  int maxEntries = 2,
  int maxManifestBytes = 65536,
  bool Function(String)? allowAdditionalFile,
}) {
  if (bytes.length > maxBytes || bytes.length < 22) {
    throw const FormatException(
      'VRZ archive exceeds its size budget or is truncated.',
    );
  }
  final data = ByteData.sublistView(bytes);
  void range(int offset, int length) {
    if (offset < 0 || length < 0 || offset > bytes.length - length) {
      throw const FormatException('Truncated or invalid ZIP range.');
    }
  }

  int u16(int at) {
    range(at, 2);
    return data.getUint16(at, Endian.little);
  }

  int u32(int at) {
    range(at, 4);
    return data.getUint32(at, Endian.little);
  }

  String name(int at, int length) {
    range(at, length);
    return utf8.decode(Uint8List.sublistView(bytes, at, at + length));
  }

  final end = bytes.length - 22;
  final entryCount = u16(end + 10);
  if (u32(end) != 0x06054b50 ||
      u16(end + 4) != 0 ||
      u16(end + 6) != 0 ||
      u16(end + 8) != entryCount ||
      entryCount < (allowManifestOnly ? 1 : 2) ||
      entryCount > maxEntries ||
      u16(end + 20) != 0) {
    throw const FormatException(
      'VRLZ requires a single-disk ZIP with its exact file set and no comment.',
    );
  }
  final centralSize = u32(end + 12);
  final centralStart = u32(end + 16);
  if (centralStart + centralSize != end) {
    throw const FormatException('Invalid ZIP central directory.');
  }
  var cursor = centralStart;
  final result = <String, Uint8List>{};
  final localRanges = <(int, int)>[];
  for (var entry = 0; entry < entryCount; entry++) {
    range(cursor, 46);
    if (u32(cursor) != 0x02014b50) {
      throw const FormatException('Missing ZIP central file header.');
    }
    final version = u16(cursor + 6);
    final flags = u16(cursor + 8);
    final method = u16(cursor + 10);
    final crc = u32(cursor + 16);
    final packed = u32(cursor + 20);
    final unpacked = u32(cursor + 24);
    final nameLength = u16(cursor + 28);
    final extraLength = u16(cursor + 30);
    final commentLength = u16(cursor + 32);
    final attributes = u32(cursor + 38);
    final local = u32(cursor + 42);
    final fileType = (attributes >> 16) & 0xf000;
    if (version > 20 ||
        (flags & ~0x0800) != 0 ||
        method != 0 ||
        packed != unpacked ||
        packed > maxBytes ||
        extraLength != 0 ||
        commentLength != 0 ||
        u16(cursor + 34) != 0 ||
        (attributes & 0x10) != 0 ||
        (fileType != 0 && fileType != 0x8000)) {
      throw const FormatException(
        'ZIP must use plain STORE files without encryption, links, extras or descriptors.',
      );
    }
    final filename = name(cursor + 46, nameLength);
    if ((!allowedFiles.contains(filename) &&
            !(allowAdditionalFile?.call(filename) ?? false)) ||
        result.containsKey(filename)) {
      throw const FormatException(
        'Unexpected, duplicate or unsafe ZIP entry name.',
      );
    }
    if (filename == 'manifest.json' && unpacked > maxManifestBytes) {
      throw const FormatException('Manifest exceeds its metadata budget.');
    }
    range(local, 30);
    if (u32(local) != 0x04034b50 ||
        u16(local + 4) != version ||
        u16(local + 6) != flags ||
        u16(local + 8) != method ||
        u32(local + 14) != crc ||
        u32(local + 18) != packed ||
        u32(local + 22) != unpacked ||
        u16(local + 26) != nameLength ||
        u16(local + 28) != 0 ||
        name(local + 30, nameLength) != filename) {
      throw const FormatException(
        'ZIP local header disagrees with central directory.',
      );
    }
    final start = local + 30 + nameLength;
    range(start, packed);
    if (start + packed > centralStart) {
      throw const FormatException('ZIP file overlaps central directory.');
    }
    final contents = Uint8List.sublistView(bytes, start, start + packed);
    if (getCrc32(contents) != crc) {
      throw const FormatException('ZIP file CRC-32 does not match its bytes.');
    }
    result[filename] = contents;
    localRanges.add((local, start + packed));
    cursor += 46 + nameLength;
  }
  localRanges.sort((a, b) => a.$1.compareTo(b.$1));
  if (cursor != end ||
      result.length != entryCount ||
      !result.containsKey('manifest.json') ||
      localRanges.first.$1 != 0 ||
      localRanges.last.$2 != centralStart) {
    throw const FormatException(
      'ZIP contains overlapping, hidden or trailing data.',
    );
  }
  for (var i = 1; i < localRanges.length; i++) {
    if (localRanges[i - 1].$2 != localRanges[i].$1) {
      throw const FormatException('ZIP contains overlapping or hidden data.');
    }
  }
  return result;
}
