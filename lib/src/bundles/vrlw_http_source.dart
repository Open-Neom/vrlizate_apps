import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:vrlizate_world/vrlizate_world.dart';

/// Strict HTTPS byte ranges over one immutable .vrlw representation.
///
/// Servers must support Range, identity content encoding, and a strong ETag.
/// Redirects and full-body fallback are rejected. Browser hosts additionally
/// need CORS access to Content-Range, Content-Encoding and ETag, and permission
/// to send Range/If-Match. A borrowed HTTP client remains caller-owned.
final class VrlwHttpSource implements VrlwByteSource {
  factory VrlwHttpSource(
    Uri uri, {
    http.Client? client,
    Duration timeout = const Duration(seconds: 15),
    String? expectedETag,
  }) {
    if (uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.port < 1 ||
        uri.port > 65535) {
      throw const FormatException(
        'VRLW sources require HTTPS without URL credentials or fragments.',
      );
    }
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'Must be positive.');
    }
    if (expectedETag != null && !_isStrongETag(expectedETag)) {
      throw const FormatException('VRLW requires a strong expected ETag.');
    }
    return VrlwHttpSource._(
      uri,
      client ?? http.Client(),
      client == null,
      timeout,
      expectedETag,
    );
  }

  VrlwHttpSource._(
    this.uri,
    this._client,
    this._ownsClient,
    this.timeout,
    this.expectedETag,
  );

  final Uri uri;
  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;
  final String? expectedETag;
  final _active = <_RangeRead>{};
  Future<void>? _firstRead;
  String? _etag;
  int? _length;
  bool _closed = false;

  @override
  int? get length => _length;

  String? get etag => _etag;

  @override
  Future<Uint8List> readRange(int offset, int length) async {
    _checkOpen();
    _validateRange(offset, length);
    // Establish one version before allowing concurrent reads. Waiting callers
    // retry initialization if an earlier read failed without accepting bytes.
    while (_etag == null) {
      if (_firstRead != null) {
        await _firstRead;
        _checkOpen();
        continue;
      }
      final gate = Completer<void>();
      _firstRead = gate.future;
      try {
        return await _read(offset, length);
      } finally {
        _firstRead = null;
        gate.complete();
      }
    }
    return _read(offset, length);
  }

  Future<Uint8List> _read(int offset, int length) async {
    _checkOpen();
    _validateRange(offset, length);
    final operation = _RangeRead();
    _active.add(operation);
    final timer = Timer(timeout, () {
      operation.cancel(
        TimeoutException('VRLW range exceeded its deadline.', timeout),
      );
    });
    try {
      final request =
          http.AbortableRequest(
              'GET',
              uri,
              abortTrigger: operation.abort.future,
            )
            ..followRedirects = false
            ..headers['range'] = 'bytes=$offset-${offset + length - 1}'
            ..headers['accept'] = 'application/octet-stream'
            ..headers['accept-encoding'] = 'identity';
      final pinnedETag = _etag ?? expectedETag;
      if (pinnedETag != null) request.headers['if-match'] = pinnedETag;
      final response = await operation.wait(
        _client.send(request).then((response) async {
          // Injected clients may ignore aborts. Cancel late bodies as well.
          if (operation.error != null) {
            unawaited(
              response.stream.listen((_) {}).cancel().catchError((Object _) {}),
            );
            throw operation.error!;
          }
          return response;
        }),
      );
      final int total;
      try {
        total = _validateResponse(response, offset, length, pinnedETag);
      } catch (_) {
        // StreamIterator is lazy: canceling one before moveNext would not
        // subscribe to and release an unused response body.
        await operation.wait(response.stream.listen((_) {}).cancel());
        rethrow;
      }
      final receivedETag = response.headers['etag']!.trim();
      final iterator = StreamIterator<List<int>>(response.stream);
      try {
        final builder = BytesBuilder(copy: false);
        while (await operation.wait(iterator.moveNext())) {
          final chunk = iterator.current;
          if (chunk.length > length - builder.length) {
            throw const FormatException('VRLW response exceeds its range.');
          }
          builder.add(chunk);
        }
        if (builder.length != length) {
          throw const FormatException('VRLW response range is incomplete.');
        }
        if (operation.error != null) throw operation.error!;
        _etag = receivedETag;
        _length = total;
        return builder.takeBytes();
      } finally {
        // Bound cancellation too: custom clients can stall their onCancel hook.
        await operation.wait(iterator.cancel());
      }
    } catch (_) {
      if (operation.error != null) throw operation.error!;
      rethrow;
    } finally {
      timer.cancel();
      operation.cancel(StateError('VRLW range request completed.'));
      _active.remove(operation);
    }
  }

  int _validateResponse(
    http.StreamedResponse response,
    int offset,
    int requestedLength,
    String? pinnedETag,
  ) {
    if (response.statusCode != 206) {
      throw FormatException(
        'VRLW requires HTTP 206; received ${response.statusCode}.',
      );
    }
    final encoding = response.headers['content-encoding'];
    if (encoding != null && encoding.trim().toLowerCase() != 'identity') {
      throw const FormatException('VRLW ranges require identity encoding.');
    }
    final range = RegExp(
      r'^bytes ([0-9]+)-([0-9]+)/([0-9]+)$',
    ).firstMatch(response.headers['content-range'] ?? '');
    final start = int.tryParse(range?.group(1) ?? '');
    final end = int.tryParse(range?.group(2) ?? '');
    final total = int.tryParse(range?.group(3) ?? '');
    if (start != offset ||
        end != offset + requestedLength - 1 ||
        total == null ||
        total <= end! ||
        total > VrlwByteSource.maxLength ||
        (_length != null && _length != total) ||
        (response.contentLength != null &&
            response.contentLength != requestedLength)) {
      throw const FormatException('VRLW Content-Range or length is invalid.');
    }
    final etag = response.headers['etag']?.trim();
    if (etag == null ||
        !_isStrongETag(etag) ||
        (pinnedETag != null && pinnedETag != etag)) {
      throw const FormatException('VRLW strong ETag is missing or changed.');
    }
    return total;
  }

  void _validateRange(int offset, int length) {
    final total = _length ?? VrlwByteSource.maxLength;
    if (offset < 0 ||
        length <= 0 ||
        length > VrlwByteSource.maxReadLength ||
        offset > total - length) {
      throw RangeError('VRLW range exceeds its source or read budget.');
    }
  }

  void _checkOpen() {
    if (_closed) throw StateError('VRLW source is closed.');
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final operation in _active.toList()) {
      operation.cancel(StateError('VRLW source was closed.'));
    }
    if (_ownsClient) _client.close();
  }

  static bool _isStrongETag(String value) =>
      RegExp(r'^"[\x21\x23-\x7e\x80-\xff]*"$').hasMatch(value);
}

final class _RangeRead {
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
