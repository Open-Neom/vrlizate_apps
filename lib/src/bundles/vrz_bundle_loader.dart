import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;

import '../catalog/vrlz_web_catalog.dart';
import 'vrlz_package.dart';
import 'vrz_bundle.dart';

/// Legacy scene-only transport. Use [VrlzPackageLoader] for all package kinds.
final class VrzBundleLoader extends _BundleLoader<VrzBundle> {
  VrzBundleLoader({
    super.client,
    super.timeout = const Duration(seconds: 30),
    super.maxDownloadBytes = VrzBundle.maxBytes,
    super.maxRedirects = 3,
  }) : super(decode: VrzBundle.decode);
}

/// Downloads and validates a scene, builtin descriptor or NES cartridge.
final class VrlzPackageLoader extends _BundleLoader<VrlzPackage> {
  VrlzPackageLoader({
    super.client,
    super.timeout = const Duration(seconds: 30),
    super.maxDownloadBytes = VrlzPackage.maxBytes,
    super.maxRedirects = 3,
  }) : super(decode: VrlzPackage.decode);
}

/// The same bounded/cancellable transport used by package and catalog loaders,
/// constrained to an exact verified resource. Redirects are never followed.
final class VrlzResourceLoader extends _BundleLoader<Uint8List> {
  VrlzResourceLoader({
    super.client,
    super.timeout = const Duration(seconds: 30),
    super.allowLocalHttp = false,
  }) : super(
         decode: (bytes, {source}) => bytes,
         maxDownloadBytes: 64 * 1024 * 1024,
         maxAllowedDownloadBytes: 64 * 1024 * 1024,
         maxRedirects: 0,
       );

  Future<Uint8List> loadVerified(
    Uri uri, {
    required int byteLength,
    required String sha256,
  }) {
    if (byteLength < 0 ||
        byteLength > maxDownloadBytes ||
        sha256.length != 64 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
      throw const FormatException('Invalid verified resource limits.');
    }
    return _load(
      uri,
      maxBytes: byteLength,
      accept: _packageAccept,
      decode: (bytes, {source}) {
        if (bytes.length != byteLength ||
            crypto.sha256.convert(bytes).toString() != sha256) {
          throw const FormatException(
            'Web resource length or SHA-256 mismatch.',
          );
        }
        return bytes;
      },
    );
  }
}

/// Loads an explicit JSON catalog and verifies its packages against that index.
/// The catalog itself is not a signature or a grant of host runtime capability.
final class VrlzWebCatalogLoader extends _BundleLoader<VrlzWebCatalog> {
  VrlzWebCatalogLoader({
    super.client,
    super.timeout = const Duration(seconds: 30),
    super.maxDownloadBytes = VrlzWebCatalog.maxBytes,
    super.maxRedirects = 3,
  }) : super(
         maxAllowedDownloadBytes: VrlzWebCatalog.maxBytes,
         accept: 'application/json',
         decode: (bytes, {source}) =>
             VrlzWebCatalog.decode(bytes, source: source!),
       );

  Future<VrlzPackage> loadPackage(VrlzWebCatalogEntry entry) => _load(
    entry.url,
    maxBytes: VrlzPackage.maxBytes,
    accept: _packageAccept,
    decode: (bytes, {source}) {
      if (crypto.sha256.convert(bytes).toString() != entry.sha256) {
        throw const FormatException(
          'VRLZ package does not match the catalog SHA-256.',
        );
      }
      final package = VrlzPackage.decode(bytes, source: source);
      if (package.id != entry.id) {
        throw const FormatException(
          'VRLZ package id does not match the catalog.',
        );
      }
      return package;
    },
  );
}

const _packageAccept = 'application/zip, application/octet-stream';
const _isBrowser = bool.fromEnvironment('dart.library.js_interop');

/// HTTPS transport with a total deadline, bounded streaming and explicit redirects.
///
/// A supplied client remains caller-owned. [close] still aborts this loader's
/// requests and cancels response subscriptions; it only closes a client it made.
class _BundleLoader<T> {
  _BundleLoader({
    http.Client? client,
    required T Function(Uint8List, {Uri? source}) decode,
    this.timeout = const Duration(seconds: 30),
    this.maxDownloadBytes = VrzBundle.maxBytes,
    this.maxRedirects = 3,
    this.allowLocalHttp = false,
    int maxAllowedDownloadBytes = VrzBundle.maxBytes,
    String accept = _packageAccept,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _decode = decode,
       _accept = accept {
    if (timeout <= Duration.zero ||
        maxDownloadBytes <= 0 ||
        maxDownloadBytes > maxAllowedDownloadBytes ||
        maxRedirects < 0 ||
        maxRedirects > 3) {
      throw ArgumentError('Invalid VRLZ download limits.');
    }
  }

  final http.Client _client;
  final bool _ownsClient;
  final T Function(Uint8List, {Uri? source}) _decode;
  final String _accept;
  final Duration timeout;
  final int maxDownloadBytes;
  final int maxRedirects;
  final bool allowLocalHttp;
  final _active = <_Download>[];
  bool _closed = false;

  Future<T> load(Uri uri) =>
      _load(uri, maxBytes: maxDownloadBytes, accept: _accept, decode: _decode);

  Future<R> _load<R>(
    Uri uri, {
    required int maxBytes,
    required String accept,
    required R Function(Uint8List, {Uri? source}) decode,
  }) async {
    if (_closed) throw StateError('VRLZ loader is closed.');
    _validateUri(uri);
    final operation = _Download();
    _active.add(operation);
    final timer = Timer(timeout, () {
      operation.cancel(
        TimeoutException('VRLZ download exceeded its deadline.', timeout),
      );
    });
    try {
      var current = uri;
      var redirects = 0;
      while (true) {
        final request =
            http.AbortableRequest(
                'GET',
                current,
                abortTrigger: operation.abort.future,
              )
              ..followRedirects = false
              ..headers['accept'] = accept;
        final response = await operation.wait(
          _client.send(request).then((response) async {
            // An injected client may ignore AbortableRequest. Release a late
            // response too when the caller already timed out or closed us.
            if (operation.error != null) {
              await response.stream.listen((_) {}).cancel();
              throw operation.error!;
            }
            return response;
          }),
        );
        if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
          await operation.wait(response.stream.listen((_) {}).cancel());
          final location = response.headers['location'];
          if (location == null ||
              location.isEmpty ||
              redirects >= maxRedirects) {
            throw const FormatException(
              'Missing redirect location or too many VRLZ redirects.',
            );
          }
          current = current.resolve(location);
          _validateUri(current);
          redirects++;
          continue;
        }
        // Fetch and HttpClient may decompress the body while retaining its
        // compressed Content-Length. In browsers CORS can additionally hide
        // Content-Encoding, so only the actual stream length is authoritative.
        final encoding = response.headers['content-encoding'];
        final encoded =
            encoding != null &&
            encoding
                .split(',')
                .any(
                  (value) =>
                      value.trim().isNotEmpty &&
                      value.trim().toLowerCase() != 'identity',
                );
        final declaredLength = _isBrowser || encoded
            ? null
            : response.contentLength;
        if (response.statusCode != 200 ||
            (declaredLength != null && declaredLength > maxBytes)) {
          await operation.wait(response.stream.listen((_) {}).cancel());
          throw FormatException(
            'VRLZ download rejected: HTTP ${response.statusCode} or excessive Content-Length.',
          );
        }
        final iterator = StreamIterator<List<int>>(response.stream);
        final builder = BytesBuilder(copy: false);
        try {
          while (await operation.wait(iterator.moveNext())) {
            final chunk = iterator.current;
            if (chunk.length > maxBytes - builder.length) {
              throw const FormatException(
                'VRLZ download exceeds its actual byte budget.',
              );
            }
            builder.add(chunk);
          }
        } finally {
          // A borrowed client's cancellation hook can itself stall; preserve
          // the same deadline and close signal while releasing the stream.
          await operation.wait(iterator.cancel());
        }
        if (declaredLength != null && declaredLength != builder.length) {
          throw const FormatException(
            'VRLZ response length is incomplete or inconsistent.',
          );
        }
        if (operation.error != null) throw operation.error!;
        return decode(builder.takeBytes(), source: current);
      }
    } catch (_) {
      if (operation.error != null) throw operation.error!;
      rethrow;
    } finally {
      timer.cancel();
      // Also abort a request when its response fails validation.
      operation.cancel(StateError('VRLZ request completed.'));
      _active.remove(operation);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final operation in _active.toList()) {
      operation.cancel(StateError('VRLZ loader was closed.'));
    }
    if (_ownsClient) _client.close();
  }

  void _validateUri(Uri uri) {
    final local =
        allowLocalHttp &&
        uri.scheme == 'http' &&
        const {'127.0.0.1', '::1'}.contains(uri.host);
    if ((uri.scheme != 'https' && !local) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.port < 1 ||
        uri.port > 65535) {
      throw const FormatException(
        'VRLZ downloads require HTTPS without URL credentials or fragments.',
      );
    }
  }
}

final class _Download {
  final abort = Completer<void>();
  Object? error;

  void cancel(Object reason) {
    if (abort.isCompleted) return;
    error = reason;
    abort.complete();
  }

  Future<T> wait<T>(Future<T> future) =>
      Future.any([future, abort.future.then<T>((_) => throw error!)]);
}
