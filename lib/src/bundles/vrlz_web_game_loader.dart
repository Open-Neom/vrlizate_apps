import 'dart:async';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'vrz_bundle_loader.dart';
import 'vrlz_web_game_cache.dart';
import 'vrlz_web_game_manifest.dart';

/// Fetches only declared files on demand; startup/unit prefetch is explicit.
/// Hash/length verification precedes cache insertion and exposure to a host.
/// The host must separately enforce its browser sandbox and network policy.
final class VrlzWebGameLoader {
  VrlzWebGameLoader(
    this.manifest, {
    http.Client? client,
    VrlzWebGameCache? cache,
    int cacheBytes = 64 * 1024 * 1024,
    this.maxConcurrentDownloads = 2,
    this.maxPendingFiles = 128,
    bool allowLocalHttp = false,
    Duration timeout = const Duration(seconds: 30),
  }) : cache = cache ?? VrlzWebGameMemoryCache(maxBytes: cacheBytes),
       _transport = VrlzResourceLoader(
         client: client,
         timeout: timeout,
         allowLocalHttp: allowLocalHttp,
       ) {
    if (maxConcurrentDownloads < 1 ||
        maxConcurrentDownloads > 4 ||
        maxPendingFiles < 1 ||
        maxPendingFiles > 1024) {
      _transport.close();
      throw ArgumentError('Invalid web download concurrency.');
    }
    if (manifest.contentBaseUrl.scheme != 'https' && !allowLocalHttp) {
      _transport.close();
      throw const FormatException(
        'Development HTTP requires explicit allowLocalHttp.',
      );
    }
  }
  final VrlzWebGameManifest manifest;
  final VrlzWebGameCache cache;
  final int maxConcurrentDownloads;
  final int maxPendingFiles;
  final VrlzResourceLoader _transport;
  final _pending = <String, Future<Uint8List>>{};
  final _waiters = <Completer<void>>[];
  final _closedSignal = Completer<void>();
  bool _closed = false;
  int _active = 0;
  int get pendingFileCount => _pending.length;

  Future<Uint8List> readFile(String path) {
    if (_closed) return Future.error(StateError('Webgame loader is closed.'));
    final file = manifest.file(path);
    final existing = _pending[path];
    if (existing != null) return existing.then(Uint8List.fromList);
    if (_pending.length >= maxPendingFiles) {
      return Future.error(StateError('Web resource request queue is full.'));
    }
    final future = _read(file);
    _pending[path] = future;
    // Do not create an unobserved error future merely to remove a pending key.
    future.then<void>(
      (_) {
        _pending.remove(path);
      },
      onError: (Object _, StackTrace __) {
        _pending.remove(path);
      },
    );
    return future.then(Uint8List.fromList);
  }

  Future<Uint8List> _read(VrlzWebGameFile file) async {
    final cached = await _wait(
      cache.read(file.sha256, byteLength: file.byteLength),
    );
    _checkOpen();
    if (cached != null &&
        verifyWebGameBytes(file.sha256, file.byteLength, cached)) {
      return cached;
    }
    if (cached != null) await _wait(cache.remove(file.sha256));
    await _acquire();
    try {
      _checkOpen();
      final uri = manifest.urlFor(file);
      if (uri.origin != manifest.contentBaseUrl.origin ||
          !uri.path.startsWith(manifest.contentBaseUrl.path)) {
        throw const FormatException('Resource escaped its declared origin.');
      }
      final bytes = await _transport.loadVerified(
        uri,
        byteLength: file.byteLength,
        sha256: file.sha256,
      );
      _checkOpen();
      await _wait(cache.write(file.sha256, bytes));
      _checkOpen();
      return bytes;
    } finally {
      _active--;
      if (_waiters.isNotEmpty) _waiters.removeAt(0).complete();
    }
  }

  Future<void> _acquire() async {
    while (_active >= maxConcurrentDownloads) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await Future.any([
        waiter.future,
        _closedSignal.future.then<void>(
          (_) => throw StateError('Webgame loader is closed.'),
        ),
      ]);
      _checkOpen();
    }
    _checkOpen();
    _active++;
  }

  Future<void> prefetchStartup() async {
    for (final unit in manifest.units.where((unit) => unit.startup)) {
      await prefetchUnit(unit.id);
    }
  }

  Future<void> prefetchUnit(String id) async {
    _checkOpen();
    for (final file in manifest.unit(id).files) {
      await readFile(file.path);
    }
  }

  /// Cache verification only; does not fetch. Useful before offering offline.
  Future<bool> isUnitCached(String id) async {
    _checkOpen();
    for (final file in manifest.unit(id).files) {
      final bytes = await _wait(
        cache.read(file.sha256, byteLength: file.byteLength),
      );
      _checkOpen();
      if (bytes == null ||
          !verifyWebGameBytes(file.sha256, file.byteLength, bytes)) {
        return false;
      }
    }
    return true;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _closedSignal.complete();
    _transport.close();
    for (final waiter in _waiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _waiters.clear();
  }

  void _checkOpen() {
    if (_closed) throw StateError('Webgame loader is closed.');
  }

  Future<T> _wait<T>(Future<T> work) => Future.any([
    work,
    _closedSignal.future.then<T>(
      (_) => throw StateError('Webgame loader is closed.'),
    ),
  ]);
}
