import 'dart:typed_data';
import 'vrlz_web_game_cache.dart';

final class VrlzWebGameFileCache implements VrlzWebGameCache {
  VrlzWebGameFileCache(
    this.directoryPath, {
    this.maxBytes = 64 * 1024 * 1024,
    this.maxFiles = 8192,
  });
  static const supported = false;
  final String directoryPath;
  @override
  final int maxBytes;
  final int maxFiles;
  int get byteLength => 0;
  int get fileCount => 0;
  Never _unsupported() =>
      throw UnsupportedError('Persistent file cache requires dart:io.');
  @override
  Future<Uint8List?> read(String hash, {required int byteLength}) async =>
      _unsupported();
  @override
  Future<void> write(String hash, Uint8List bytes) async => _unsupported();
  @override
  Future<void> remove(String hash) async => _unsupported();
  @override
  Future<void> clear() async => _unsupported();
  Future<void> prune() async => _unsupported();
}
