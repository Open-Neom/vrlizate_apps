import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;

/// Content-addressed verified resource storage. Implementations copy buffers;
/// cache hits are rechecked before executable web bytes leave the loader.
abstract interface class VrlzWebGameCache {
  int get maxBytes;
  Future<Uint8List?> read(String sha256, {required int byteLength});
  Future<void> write(String sha256, Uint8List bytes);
  Future<void> remove(String sha256);
  Future<void> clear();
}

final class VrlzWebGameMemoryCache implements VrlzWebGameCache {
  VrlzWebGameMemoryCache({this.maxBytes = 64 * 1024 * 1024}) {
    if (maxBytes < 1 || maxBytes > 1024 * 1024 * 1024) {
      throw ArgumentError('Invalid web cache quota.');
    }
  }
  @override
  final int maxBytes;
  final _entries = <String, Uint8List>{};
  int _bytes = 0;
  int get byteLength => _bytes;
  int get fileCount => _entries.length;
  @override
  Future<Uint8List?> read(String hash, {required int byteLength}) async {
    validateWebGameHash(hash);
    final bytes = _entries.remove(hash);
    if (bytes == null) return null;
    if (!verifyWebGameBytes(hash, byteLength, bytes)) {
      _bytes -= bytes.length;
      return null;
    }
    _entries[hash] = bytes;
    return Uint8List.fromList(bytes);
  }

  @override
  Future<void> write(String hash, Uint8List bytes) async {
    validateWebGameHash(hash);
    final owned = Uint8List.fromList(bytes);
    if (!verifyWebGameBytes(hash, owned.length, owned)) {
      throw const FormatException('Invalid web cache bytes.');
    }
    // This mutation is synchronous: equal hashes arriving from distinct paths
    // cannot interleave an awaited removal and count the same resource twice.
    _bytes -= _entries.remove(hash)?.length ?? 0;
    if (owned.length > maxBytes) return;
    while (_entries.isNotEmpty && _bytes + owned.length > maxBytes) {
      final removed = _entries.remove(_entries.keys.first)!;
      _bytes -= removed.length;
    }
    _entries[hash] = owned;
    _bytes += owned.length;
  }

  @override
  Future<void> remove(String hash) async {
    validateWebGameHash(hash);
    _bytes -= _entries.remove(hash)?.length ?? 0;
  }

  @override
  Future<void> clear() async {
    _entries.clear();
    _bytes = 0;
  }
}

void validateWebGameHash(String hash) {
  if (hash.length != 64 || !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
    throw const FormatException('Invalid content hash.');
  }
}

bool verifyWebGameBytes(String hash, int size, Uint8List bytes) =>
    bytes.length == size && crypto.sha256.convert(bytes).toString() == hash;
