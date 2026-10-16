import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:vrlizate_apps/vrlizate_apps.dart';

import 'support/vrz_fixture.dart';

final _indexUrl = Uri.parse('https://example.org/catalog/index.json');

void main() {
  test('resolves relative HTTPS entries and exposes immutable metadata', () {
    final json = _indexJson();
    final catalog = VrlzWebCatalog.decode(_encode(json), source: _indexUrl);
    expect(catalog.source, _indexUrl);
    expect(catalog.entries.single.id, 'org.example.room');
    expect(catalog.entries.single.title, 'Web catalog title');
    expect(
      catalog.entries.single.url,
      Uri.parse('https://example.org/catalog/room.vrlz'),
    );
    json['packages'][0]['title'] = 'Mutation after decode';
    expect(catalog.entries.single.title, 'Web catalog title');
    expect(() => catalog.entries.clear(), throwsUnsupportedError);
  });

  final badIndexes = <String, void Function(Map<String, dynamic>)>{
    'future format': (j) => j['formatVersion'] = 2,
    'floating format': (j) => j['formatVersion'] = 1.0,
    'unknown root field': (j) => j['script'] = 'main.js',
    'missing packages': (j) => j.remove('packages'),
    'object packages': (j) => j['packages'] = {},
    'unknown entry field': (j) => j['packages'][0]['runtime'] = 'dart',
    'missing entry hash': (j) => j['packages'][0].remove('sha256'),
    'invalid hash': (j) => j['packages'][0]['sha256'] = 'A' * 64,
    'wrong title type': (j) => j['packages'][0]['title'] = 9,
    'empty title': (j) => j['packages'][0]['title'] = ' ',
    'long title': (j) => j['packages'][0]['title'] = 'a' * 81,
    'invalid id': (j) => j['packages'][0]['id'] = 'room',
    'id newline': (j) => j['packages'][0]['id'] = 'org.room\n',
    'HTTP URL': (j) => j['packages'][0]['url'] = 'http://example.org/a.vrlz',
    'file URL': (j) => j['packages'][0]['url'] = 'file:///a.vrlz',
    'script URL': (j) => j['packages'][0]['url'] = 'javascript:alert(1)',
    'credential URL': (j) =>
        j['packages'][0]['url'] = 'https://u:p@example.org/a.vrlz',
    'fragment URL': (j) => j['packages'][0]['url'] = 'room.vrlz#ignored',
    'empty fragment URL': (j) => j['packages'][0]['url'] = 'room.vrlz#',
    'empty URL': (j) => j['packages'][0]['url'] = '',
    'too long URL': (j) => j['packages'][0]['url'] = 'a' * 2049,
  };
  for (final item in badIndexes.entries) {
    test('rejects catalog ${item.key}', () {
      final json = _indexJson();
      item.value(json);
      expect(
        () => VrlzWebCatalog.decode(_encode(json), source: _indexUrl),
        throwsFormatException,
      );
    });
  }

  test(
    'rejects duplicate ids and URL aliases while allowing another HTTPS host',
    () {
      for (final change in <void Function(Map<String, dynamic>)>[
        (entry) => entry['url'] = 'another.vrlz',
        (entry) => entry['id'] = 'org.example.other',
        (entry) {
          entry['id'] = 'org.example.other';
          entry['url'] = 'https://example.org:443/catalog/./room.vrlz';
        },
      ]) {
        final json = _indexJson();
        final entry = Map<String, dynamic>.from(json['packages'][0] as Map);
        change(entry);
        (json['packages'] as List).add(entry);
        expect(
          () => VrlzWebCatalog.decode(_encode(json), source: _indexUrl),
          throwsFormatException,
        );
      }
      final json = _indexJson();
      json['packages'][0]['url'] = 'https://cdn.example.net/room.vrlz';
      expect(
        VrlzWebCatalog.decode(
          _encode(json),
          source: _indexUrl,
        ).entries.single.url.host,
        'cdn.example.net',
      );
    },
  );

  test('bounds index bytes, entry count, nesting and source scheme', () {
    final many = _indexJson();
    final entry = Map<String, dynamic>.from(many['packages'][0] as Map);
    many['packages'] = List.generate(
      129,
      (i) => {...entry, 'id': 'org.item$i', 'url': '$i.vrlz'},
    );
    final deep = '{"formatVersion":1,"packages":${'[' * 65}${']' * 65}}';
    for (final bytes in [
      Uint8List(VrlzWebCatalog.maxBytes + 1),
      _encode(many),
      Uint8List.fromList(utf8.encode(deep)),
      Uint8List.fromList([0xff]),
      _encode([]),
    ]) {
      expect(
        () => VrlzWebCatalog.decode(bytes, source: _indexUrl),
        throwsFormatException,
      );
    }
    expect(
      () => VrlzWebCatalog.decode(
        _encode(_indexJson()),
        source: Uri.parse('http://example.org/index.json'),
      ),
      throwsFormatException,
    );
    final empty = VrlzWebCatalog.decode(
      _encode({'formatVersion': 1, 'packages': []}),
      source: _indexUrl,
    );
    expect(empty.entries, isEmpty);
  });

  test(
    'loader resolves against final index URL and verifies package hash and id',
    () async {
      final bytes = fixtureBuiltin();
      final calls = <Uri>[];
      final client = _Client((request) async {
        calls.add(request.url);
        if (request.url == _indexUrl) {
          expect(request.headers['accept'], 'application/json');
          return http.StreamedResponse(
            const Stream.empty(),
            302,
            headers: {'location': '/published/index.json'},
          );
        }
        if (request.url.path.endsWith('.json')) {
          expect(request.headers['accept'], 'application/json');
          return http.StreamedResponse(
            Stream.value(_encode(_indexJson(bytes: bytes))),
            200,
          );
        }
        expect(request.headers['accept'], contains('application/zip'));
        return http.StreamedResponse(
          Stream.value(bytes),
          200,
          contentLength: bytes.length,
        );
      });
      final loader = VrlzWebCatalogLoader(client: client);
      addTearDown(loader.close);
      final catalog = await loader.load(_indexUrl);
      expect(
        catalog.source,
        Uri.parse('https://example.org/published/index.json'),
      );
      final entry = catalog.entries.single;
      expect(entry.url, Uri.parse('https://example.org/published/room.vrlz'));
      final package = await loader.loadPackage(entry);
      expect(package.id, entry.id);
      expect(package.demoId, 'flutter_scene_room');
      expect(
        package.title,
        'Cuarto integrado',
        reason: 'Index titles do not override package metadata.',
      );
      expect(calls, [_indexUrl, catalog.source, entry.url]);
    },
  );

  test('accepts decoded HTTP bodies with a compressed wire length', () async {
    final bytes = fixtureBuiltin();
    final client = _Client((request) async {
      final body = request.url.path.endsWith('.json')
          ? _encode(_indexJson(bytes: bytes))
          : bytes;
      // This models HttpClient/fetch after transparent HTTP decompression.
      return http.StreamedResponse(
        Stream.value(body),
        200,
        headers: {'content-encoding': 'gzip'},
        contentLength: 7,
      );
    });
    final loader = VrlzWebCatalogLoader(client: client);
    addTearDown(loader.close);
    final index = await loader.load(_indexUrl);
    final package = await loader.loadPackage(index.entries.single);
    expect(package.demoId, 'flutter_scene_room');
  });

  test(
    'package verification rejects wrong checksum, wrong id and malformed payload',
    () async {
      for (final mode in ['hash', 'id', 'payload']) {
        final bytes = fixtureBuiltin();
        if (mode == 'payload') bytes[14] ^= 1;
        final json = _indexJson(bytes: bytes);
        if (mode == 'hash') json['packages'][0]['sha256'] = '0' * 64;
        if (mode == 'id') json['packages'][0]['id'] = 'org.example.other';
        final entry = VrlzWebCatalog.decode(
          _encode(json),
          source: _indexUrl,
        ).entries.single;
        final client = _Client(
          (_) async => http.StreamedResponse(Stream.value(bytes), 200),
        );
        final loader = VrlzWebCatalogLoader(client: client);
        await expectLater(loader.loadPackage(entry), throwsFormatException);
        loader.close();
      }
    },
  );

  test(
    'package budget is independent from the small JSON index budget',
    () async {
      final scene = triangleGlb(
        changeJson: (j) => j['nodes'][0]['name'] = 'n' * 300000,
      );
      final bytes = VrzBundle.encode(
        sceneBytes: scene,
        id: 'org.example.room',
        title: 'Scene',
      );
      expect(bytes.length, greaterThan(VrlzWebCatalog.maxBytes));
      final entry = VrlzWebCatalog.decode(
        _encode(_indexJson(bytes: bytes)),
        source: _indexUrl,
      ).entries.single;
      final client = _Client(
        (_) async => http.StreamedResponse(Stream.value(bytes), 200),
      );
      final loader = VrlzWebCatalogLoader(client: client);
      addTearDown(loader.close);
      final package = await loader.loadPackage(entry);
      expect(package.sceneBundle!.sceneBytes, scene);
    },
  );

  test(
    'catalog byte budget applies to actual streaming and cannot be enlarged',
    () async {
      expect(
        () =>
            VrlzWebCatalogLoader(maxDownloadBytes: VrlzWebCatalog.maxBytes + 1),
        throwsArgumentError,
      );
      var canceled = false;
      final response = StreamController<List<int>>(
        onCancel: () => canceled = true,
      );
      final client = _Client(
        (_) async => http.StreamedResponse(response.stream, 200),
      );
      final loader = VrlzWebCatalogLoader(client: client, maxDownloadBytes: 8);
      addTearDown(loader.close);
      final failure = expectLater(
        loader.load(_indexUrl),
        throwsFormatException,
      );
      response.add(List.filled(9, 0));
      await failure;
      expect(canceled, isTrue);
    },
  );

  test(
    'close aborts simultaneous index and package requests but preserves borrowed client',
    () async {
      final entry = VrlzWebCatalog.decode(
        _encode(_indexJson()),
        source: _indexUrl,
      ).entries.single;
      final pendingHeaders = <Completer<http.StreamedResponse>>[];
      var aborts = 0;
      final client = _Client((request) {
        (request as http.AbortableRequest).abortTrigger!.then((_) => aborts++);
        final headers = Completer<http.StreamedResponse>();
        pendingHeaders.add(headers);
        return headers.future;
      });
      final loader = VrlzWebCatalogLoader(client: client);
      final indexFailure = expectLater(
        loader.load(_indexUrl),
        throwsStateError,
      );
      final packageFailure = expectLater(
        loader.loadPackage(entry),
        throwsStateError,
      );
      loader.close();
      loader.close();
      await Future.wait([indexFailure, packageFailure]);
      expect(aborts, 2);
      expect(client.closed, isFalse);
      for (final headers in pendingHeaders) {
        headers.complete(http.StreamedResponse(const Stream.empty(), 200));
      }
      await expectLater(loader.loadPackage(entry), throwsStateError);
    },
  );
}

Map<String, dynamic> _indexJson({Uint8List? bytes}) => {
  'formatVersion': 1,
  'packages': <dynamic>[
    <String, dynamic>{
      'id': 'org.example.room',
      'title': 'Web catalog title',
      'url': 'room.vrlz',
      'sha256': sha256.convert(bytes ?? fixtureBuiltin()).toString(),
    },
  ],
};

Uint8List _encode(Object value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

class _Client extends http.BaseClient {
  _Client(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
  @override
  void close() => closed = true;
}
