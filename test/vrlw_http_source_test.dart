import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:vrlizate_apps/src/bundles/vrlw_http_source.dart';
import 'package:vrlizate_world/vrlizate_world.dart';

final _url = Uri.parse('https://example.org/places/plaza.vrlw');

http.StreamedResponse _response({
  Stream<List<int>>? stream,
  int status = 206,
  int start = 0,
  int count = 4,
  int total = 32,
  String? etag = '"version-1"',
  String? encoding,
  int? contentLength,
}) => http.StreamedResponse(
  stream ?? Stream.value(List.generate(count, (index) => start + index)),
  status,
  contentLength: contentLength,
  headers: {
    'content-range': 'bytes $start-${start + count - 1}/$total',
    if (etag != null) 'etag': etag,
    if (encoding != null) 'content-encoding': encoding,
  },
);

void main() {
  test(
    'streams only index and selected region, then revisits from packed cache',
    () async {
      final bytes = VrlwBundleCodec.encode({
        'schemaVersion': 1,
        'id': 'test.range-place',
        'title': 'Selective HTTPS place',
        'revision': '1',
        'license': 'CC0-1.0',
        'gridId': 'local-12m',
        'cellSizeMeters': 12,
        'origin': {'type': 'local'},
        'prototypes': ['tree'],
        'regions': [
          for (var cell = 0; cell < 8; cell++)
            {
              'x': cell,
              'z': 0,
              'entities': [
                for (var tree = 0; tree < 8; tree++)
                  {
                    'id': 'tree:$cell:$tree',
                    'prototypeId': 'tree',
                    'x': tree + .5,
                    'y': 0,
                    'z': 2,
                  },
              ],
            },
        ],
      });
      final header = VrlwBundleCodec.parseHeader(
        bytes.sublist(0, VrlwBundleCodec.headerSize),
      );
      final trustedIndex = VrlwBundleCodec.parseIndex(
        header,
        bytes.sublist(VrlwBundleCodec.headerSize, header.payloadOffset),
      );
      final ranges = <(int, int)>[];
      final client = _Client((request) async {
        expect(request.headers['if-match'], '"place-1"');
        expect(request.headers['accept-encoding'], 'identity');
        final match = RegExp(
          r'^bytes=([0-9]+)-([0-9]+)$',
        ).firstMatch(request.headers['range']!)!;
        final start = int.parse(match.group(1)!);
        final end = int.parse(match.group(2)!);
        ranges.add((start, end - start + 1));
        return _response(
          start: start,
          count: end - start + 1,
          total: bytes.length,
          etag: '"place-1"',
          contentLength: end - start + 1,
          stream: Stream.value(bytes.sublist(start, end + 1)),
        );
      });
      final source = VrlwHttpSource(
        _url,
        client: client,
        expectedETag: '"place-1"',
      );
      addTearDown(source.close);
      final reader = await VrlwPlaceReader.open(
        source,
        registeredPrototypeIds: {'tree'},
        expectedIndexSha256: trustedIndex.indexSha256,
      );
      expect(ranges, [
        (0, VrlwBundleCodec.headerSize),
        (VrlwBundleCodec.headerSize, header.manifestLength),
      ]);
      expect(source.etag, '"place-1"');
      final packedCache = <String, Uint8List>{};
      final provider = VrlwRegionProvider(
        reader,
        readCache: (key) async => packedCache[key],
        writeCache: (key, packed) async {
          packedCache[key] = Uint8List.fromList(packed);
          return true;
        },
      );
      final cache = VrRegionCache<List<VrWorldEntity>>(
        grid: provider.grid,
        provider: provider.load,
        maxEntries: 1,
        prefetchRadiusCells: 0,
        retentionRadiusCells: 0,
      );
      addTearDown(cache.dispose);
      cache.updatePosition(VrWorldPosition(37, 1.6, 1));
      await cache.waitForIdle();
      expect(cache.snapshot.errors, isEmpty);
      final selected = trustedIndex.chunkAt(3, 0)!;
      expect(ranges.last, (
        header.payloadOffset + selected.offset,
        selected.packedBytes,
      ));
      expect(client.sends, 3);
      expect(provider.sourceReads, 1);
      expect(cache.snapshot.currentData!.value, hasLength(8));
      expect(
        cache.snapshot.currentData!.value.first.transform.position.x,
        36.5,
      );
      expect(
        ranges.fold<int>(0, (sum, range) => sum + range.$2),
        lessThan(bytes.length),
      );

      // Leaving for an absent region evicts decoded data under a one-entry
      // budget. Returning must reconstruct it from the verified packed cache.
      cache.updatePosition(VrWorldPosition(-1, 1.6, 1));
      await cache.waitForIdle();
      expect(cache.peek(provider.grid.key(3, 0)), isNull);
      cache.updatePosition(VrWorldPosition(37, 1.6, 1));
      await cache.waitForIdle();
      expect(cache.snapshot.errors, isEmpty);
      expect(cache.snapshot.currentData!.value, hasLength(8));
      expect(provider.cacheHits, 1);
      expect(provider.sourceReads, 1);
      expect(client.sends, 3);
    },
  );
  test(
    'requests exact ranges and pins the version on subsequent reads',
    () async {
      final client = _Client((request) async {
        expect(request, isA<http.AbortableRequest>());
        expect(request.followRedirects, isFalse);
        expect(request.url, _url);
        expect(request.headers['accept-encoding'], 'identity');
        if (request.headers['range'] == 'bytes=0-3') {
          expect(request.headers['if-match'], isNull);
          return _response();
        }
        expect(request.headers['range'], 'bytes=8-11');
        expect(request.headers['if-match'], '"version-1"');
        return _response(start: 8);
      });
      final source = VrlwHttpSource(_url, client: client);
      addTearDown(source.close);
      expect(source.length, isNull);
      expect(await source.readRange(0, 4), [0, 1, 2, 3]);
      expect(source.length, 32);
      expect(source.etag, '"version-1"');
      expect(await source.readRange(8, 4), [8, 9, 10, 11]);
    },
  );

  test(
    'serializes initial reads so they cannot establish different versions',
    () async {
      final firstHeaders = Completer<http.StreamedResponse>();
      final client = _Client((request) async {
        if (request.headers['range'] == 'bytes=0-3') return firstHeaders.future;
        expect(request.headers['if-match'], '"version-1"');
        return _response(start: 8);
      });
      final source = VrlwHttpSource(_url, client: client);
      addTearDown(source.close);
      final first = source.readRange(0, 4);
      final second = source.readRange(8, 4);
      await Future<void>.delayed(Duration.zero);
      expect(client.sends, 1);
      firstHeaders.complete(_response());
      expect(await first, [0, 1, 2, 3]);
      expect(await second, [8, 9, 10, 11]);
    },
  );

  test('an expected ETag pins even the initial request', () async {
    final client = _Client((request) async {
      expect(request.headers['if-match'], '"pinned"');
      return _response(etag: '"pinned"');
    });
    final source = VrlwHttpSource(
      _url,
      client: client,
      expectedETag: '"pinned"',
    );
    addTearDown(source.close);
    await source.readRange(0, 4);
  });

  test('validates URI, deadline and expected ETag before transport', () {
    final client = _Client((_) => throw StateError('must not send'));
    for (final url in [
      'http://example.org/a.vrlw',
      'file:///a.vrlw',
      'https://user:pass@example.org/a.vrlw',
      'https://example.org/a.vrlw#hidden',
    ]) {
      expect(
        () => VrlwHttpSource(Uri.parse(url), client: client),
        throwsFormatException,
      );
    }
    for (final etag in ['W/"weak"', 'unquoted', '"bad\nvalue"']) {
      expect(
        () => VrlwHttpSource(_url, client: client, expectedETag: etag),
        throwsFormatException,
      );
    }
    expect(
      () => VrlwHttpSource(_url, client: client, timeout: Duration.zero),
      throwsArgumentError,
    );
    expect(client.sends, 0);
  });

  test('rejects full-body fallback, redirects and server errors', () async {
    for (final status in [200, 301, 302, 307, 404, 412, 416, 500]) {
      var canceled = false;
      final stream = StreamController<List<int>>(
        onCancel: () => canceled = true,
      );
      final client = _Client(
        (_) async => _response(status: status, stream: stream.stream),
      );
      final source = VrlwHttpSource(_url, client: client);
      await expectLater(source.readRange(0, 4), throwsFormatException);
      expect(canceled, isTrue);
      expect(client.sends, 1);
      await source.close();
    }
  });

  test(
    'rejects mismatched ranges, oversized totals and declared lengths',
    () async {
      for (final response in [
        _response(start: 1),
        _response(count: 3),
        _response(total: 3),
        _response(total: VrlwByteSource.maxLength + 1),
        _response(contentLength: 5),
        http.StreamedResponse(
          const Stream.empty(),
          206,
          headers: {'content-range': 'bytes 0-3/*', 'etag': '"version-1"'},
        ),
        http.StreamedResponse(
          const Stream.empty(),
          206,
          headers: {
            'content-range': 'bytes 0-3/9999999999999999999999999999999999999',
            'etag': '"version-1"',
          },
        ),
      ]) {
        final source = VrlwHttpSource(
          _url,
          client: _Client((_) async => response),
        );
        await expectLater(source.readRange(0, 4), throwsFormatException);
        expect(source.length, isNull);
        await source.close();
      }
    },
  );

  test('rejects content encoding and absent or weak ETags', () async {
    for (final response in [
      _response(encoding: 'gzip'),
      _response(encoding: 'br'),
      _response(etag: null),
      _response(etag: 'W/"weak"'),
      _response(etag: 'bare'),
    ]) {
      final source = VrlwHttpSource(
        _url,
        client: _Client((_) async => response),
      );
      await expectLater(source.readRange(0, 4), throwsFormatException);
      await source.close();
    }
  });

  test('rejects version or total size changes after initial read', () async {
    for (final changed in [
      _response(start: 8, etag: '"version-2"'),
      _response(start: 8, total: 64),
    ]) {
      var calls = 0;
      final source = VrlwHttpSource(
        _url,
        client: _Client((_) async => calls++ == 0 ? _response() : changed),
      );
      await source.readRange(0, 4);
      await expectLater(source.readRange(8, 4), throwsFormatException);
      expect(source.length, 32);
      expect(source.etag, '"version-1"');
      await source.close();
    }
  });

  test(
    'rejects a different first ETag when an expected version was provided',
    () async {
      final source = VrlwHttpSource(
        _url,
        client: _Client((_) async => _response()),
        expectedETag: '"expected"',
      );
      addTearDown(source.close);
      await expectLater(source.readRange(0, 4), throwsFormatException);
    },
  );

  test('bounds actual streamed bytes even without Content-Length', () async {
    for (final bytes in [
      <int>[0, 1, 2],
      <int>[0, 1, 2, 3, 4],
    ]) {
      final source = VrlwHttpSource(
        _url,
        client: _Client((_) async => _response(stream: Stream.value(bytes))),
      );
      await expectLater(source.readRange(0, 4), throwsFormatException);
      await source.close();
    }
  });

  test(
    'rejects invalid read bounds before transport and uses known total',
    () async {
      final client = _Client((_) async => _response());
      final source = VrlwHttpSource(_url, client: client);
      addTearDown(source.close);
      for (final range in [
        (-1, 1),
        (0, 0),
        (0, -1),
        (0, VrlwByteSource.maxReadLength + 1),
        (VrlwByteSource.maxLength, 1),
      ]) {
        await expectLater(
          source.readRange(range.$1, range.$2),
          throwsRangeError,
        );
      }
      expect(client.sends, 0);
      await source.readRange(0, 4);
      await expectLater(source.readRange(32, 1), throwsRangeError);
      expect(client.sends, 1);
    },
  );

  test('reports network errors and permits a fresh initial attempt', () async {
    var attempts = 0;
    final source = VrlwHttpSource(
      _url,
      client: _Client(
        (_) async => attempts++ == 0
            ? _response(stream: Stream.error(http.ClientException('offline')))
            : _response(),
      ),
    );
    addTearDown(source.close);
    await expectLater(
      source.readRange(0, 4),
      throwsA(isA<http.ClientException>()),
    );
    expect(await source.readRange(0, 4), [0, 1, 2, 3]);
  });

  test('deadline aborts pending headers and cancels a late response', () async {
    final headers = Completer<http.StreamedResponse>();
    var aborted = false;
    final client = _Client((request) {
      (request as http.AbortableRequest).abortTrigger!.then(
        (_) => aborted = true,
      );
      return headers.future;
    });
    final source = VrlwHttpSource(
      _url,
      client: client,
      timeout: const Duration(milliseconds: 10),
    );
    addTearDown(source.close);
    await expectLater(source.readRange(0, 4), throwsA(isA<TimeoutException>()));
    expect(aborted, isTrue);
    var canceled = false;
    final lateStream = StreamController<List<int>>(
      onCancel: () => canceled = true,
    );
    headers.complete(_response(stream: lateStream.stream));
    await Future<void>.delayed(Duration.zero);
    expect(canceled, isTrue);
  });

  test('deadline cancels a stalled body', () async {
    var canceled = false;
    final stream = StreamController<List<int>>(onCancel: () => canceled = true);
    final source = VrlwHttpSource(
      _url,
      client: _Client((_) async => _response(stream: stream.stream)),
      timeout: const Duration(milliseconds: 10),
    );
    addTearDown(source.close);
    await expectLater(source.readRange(0, 4), throwsA(isA<TimeoutException>()));
    expect(canceled, isTrue);
  });

  test('deadline bounds a stalled cancellation hook', () async {
    final never = Completer<void>();
    final stream = StreamController<List<int>>(onCancel: () => never.future);
    final source = VrlwHttpSource(
      _url,
      client: _Client(
        (_) async => _response(status: 200, stream: stream.stream),
      ),
      timeout: const Duration(milliseconds: 10),
    );
    addTearDown(source.close);
    await expectLater(source.readRange(0, 4), throwsA(isA<TimeoutException>()));
    never.complete();
  });

  test(
    'close aborts active and queued reads and preserves a borrowed client',
    () async {
      final headers = Completer<http.StreamedResponse>();
      final client = _Client((_) => headers.future);
      final source = VrlwHttpSource(_url, client: client);
      final first = expectLater(source.readRange(0, 4), throwsStateError);
      final queued = expectLater(source.readRange(8, 4), throwsStateError);
      await source.close();
      await source.close();
      await Future.wait([first, queued]);
      await expectLater(source.readRange(0, 4), throwsStateError);
      expect(client.closed, isFalse);
      headers.complete(_response());
      await Future<void>.delayed(Duration.zero);
    },
  );
}

final class _Client extends http.BaseClient {
  _Client(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  int sends = 0;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    sends++;
    return handler(request);
  }

  @override
  void close() => closed = true;
}
