import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:vrlizate_apps/vrlizate_apps.dart';
import 'package:vrlizate_apps/src/bundles/vrz_zip.dart';
import 'support/web_game_fixture.dart';

void main() {
  test(
    'browser requirements are optional and empty indices preserve legacy bytes',
    () {
      final json = webGameJson();
      final original = VrlzWebGameManifest.fromJson(json);
      expect(original.requirements, isEmpty);
      expect(original.toJson().containsKey('requirements'), isFalse);
      final bytes = VrlzPackage.encodeWebGame(manifest: original);
      json['requirements'] = <String>[];
      final explicitEmpty = VrlzWebGameManifest.fromJson(json);
      expect(explicitEmpty.toJson(), original.toJson());
      expect(VrlzPackage.encodeWebGame(manifest: explicitEmpty), bytes);
    },
  );
  test(
    'browser requirements roundtrip and cannot be changed after validation',
    () {
      final json = webGameJson();
      json['requirements'] = ['wasm-gc', 'webgl2', 'cross-origin-isolation'];
      final manifest = VrlzWebGameManifest.fromJson(json);
      final decoded = VrlzPackage.decode(
        VrlzPackage.encodeWebGame(manifest: manifest),
      );
      expect(decoded.webGameManifest!.requirements, [
        'wasm-gc',
        'webgl2',
        'cross-origin-isolation',
      ]);
      expect(() => manifest.requirements.add('webgl2'), throwsUnsupportedError);
    },
  );
  test(
    'browser requirements reject unknown, duplicate, excessive and non-list claims',
    () {
      for (final invalid in <Object?>[
        null,
        'wasm-gc',
        {'wasm-gc': true},
        [true],
        ['native.filesystem'],
        ['wasm-gc', 'wasm-gc'],
        ['wasm-gc', 'webgl2', 'cross-origin-isolation', 'webgl2'],
        ['webgl2;alert(1)'],
      ]) {
        final json = webGameJson();
        json['requirements'] = invalid;
        expect(
          () => VrlzWebGameManifest.fromJson(json),
          throwsFormatException,
          reason: '$invalid',
        );
      }
    },
  );
  test(
    'local source offers require the exact opted-in content loopback origin',
    () {
      final json = webGameJson();
      json['contentBaseUrl'] = 'http://127.0.0.1:8787/games/';
      json['sourceArchiveUrl'] = 'http://127.0.0.1:8787/source/game.zip';
      expect(
        VrlzWebGameManifest.fromJson(json).sourceArchiveUrl.scheme,
        'http',
      );
      json['sourceArchiveUrl'] = 'http://127.0.0.1:8788/source/game.zip';
      expect(() => VrlzWebGameManifest.fromJson(json), throwsFormatException);
      json['contentBaseUrl'] = 'https://games.example/games/';
      json['sourceArchiveUrl'] = 'http://127.0.0.1:8787/source/game.zip';
      expect(() => VrlzWebGameManifest.fromJson(json), throwsFormatException);
    },
  );
  test(
    'concurrent equal-content writes preserve byte accounting and own their input',
    () async {
      final files = webGameFiles();
      final file = VrlzWebGameManifest.fromJson(webGameJson()).file('main.js');
      final input = Uint8List.fromList(files[file.path]!);
      final cache = VrlzWebGameMemoryCache();
      final a = cache.write(file.sha256, input),
          b = cache.write(file.sha256, input);
      input[0] = 0;
      await a;
      await b;
      expect(cache.byteLength, file.byteLength);
      expect(cache.fileCount, 1);
      expect(
        await cache.read(file.sha256, byteLength: file.byteLength),
        files[file.path],
      );
    },
  );
  test(
    'large web indices use their explicit budget without raising legacy ZIP limits',
    () {
      final json = webGameJson();
      (json['units'] as List).add({
        'id': 'many_resources',
        'startup': false,
        'files': [
          for (var i = 0; i < 500; i++)
            {
              'path': 'assets/${'x' * 90}_$i.bin',
              'byteLength': 0,
              'sha256':
                  'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
              'mediaType': 'application/octet-stream',
            },
        ],
      });
      final manifest = VrlzWebGameManifest.fromJson(json);
      final bytes = VrlzPackage.encodeWebGame(manifest: manifest);
      expect(bytes.length, greaterThan(65536));
      expect(VrlzPackage.decode(bytes).webGameManifest!.files, hasLength(504));
      expect(
        () => readVrzZip(bytes, VrlzPackage.maxBytes, allowManifestOnly: true),
        throwsFormatException,
      );
    },
  );
  test('portrait viewports fit the bounded pixel budget', () {
    final json = webGameJson();
    final defaultManifest = VrlzWebGameManifest.fromJson(json);
    expect(defaultManifest.viewportWidth, 1280);
    expect(defaultManifest.viewportHeight, 720);
    json['viewportWidth'] = 720;
    json['viewportHeight'] = 960;
    expect(VrlzWebGameManifest.fromJson(json).viewportHeight, 960);
    for (final size in [(1920, 1920), (239, 720), (1280.0, 720), (2048, 720)]) {
      json['viewportWidth'] = size.$1;
      json['viewportHeight'] = size.$2;
      expect(() => VrlzWebGameManifest.fromJson(json), throwsFormatException);
    }
  });
  test(
    'webgame is a portable index and roundtrips through existing package loader',
    () async {
      final manifest = VrlzWebGameManifest.fromJson(webGameJson());
      final bytes = VrlzPackage.encodeWebGame(manifest: manifest);
      final client = _Client(
        (_) async => http.StreamedResponse(Stream.value(bytes), 200),
      );
      final loader = VrlzPackageLoader(client: client);
      addTearDown(loader.close);
      final package = await loader.load(
        Uri.parse('https://games.example/game.vrlz'),
      );
      expect(package.kind, VrlzPackageKind.webgame);
      expect(package.webGameManifest!.portable, isTrue);
      expect(package.id, manifest.id);
      expect(package.title, manifest.title);
      expect(package.demoId, isNull);
      expect(package.sceneBundle, isNull);
      expect(package.webGameManifest!.files, hasLength(4));
      expect(package.encode(), bytes);
      expect(bytes.length, lessThan(4096));
      final cache = VrlzWebGameMemoryCache();
      expect(
        await cache.read(
          manifest.files.first.sha256,
          byteLength: manifest.files.first.byteLength,
        ),
        isNull,
      );
    },
  );

  test(
    'rejects unsafe paths, undeclared entrypoint, duplicate files and executable extras',
    () {
      for (final path in [
        '../index.html',
        '/index.html',
        'maps/../a',
        'maps//a',
        'maps/%2e%2e/a',
        r'maps\a',
        'https://evil/a',
        'a\n',
      ]) {
        final json = webGameJson();
        (json['units'] as List).first['files'][0]['path'] = path;
        expect(
          () => VrlzWebGameManifest.fromJson(json),
          throwsFormatException,
          reason: path,
        );
      }
      var json = webGameJson();
      json['entrypoint'] = 'missing.html';
      expect(() => VrlzWebGameManifest.fromJson(json), throwsFormatException);
      json = webGameJson();
      (json['units'] as List).first['startup'] = false;
      expect(() => VrlzWebGameManifest.fromJson(json), throwsFormatException);
      json = webGameJson();
      (json['units'] as List)[1]['files'][0]['path'] = 'INDEX.HTML';
      expect(() => VrlzWebGameManifest.fromJson(json), throwsFormatException);
      final manifest = VrlzWebGameManifest.fromJson(webGameJson());
      final package = VrlzPackage.encodeWebGame(manifest: manifest);
      final files = readVrzZip(
        package,
        VrlzPackage.maxBytes,
        allowManifestOnly: true,
      );
      final extra = writeVrzStoreZip({
        ...files,
        'level.json': Uint8List(0),
      }, VrlzPackage.maxBytes);
      expect(() => VrlzPackage.decode(extra), throwsFormatException);
    },
  );

  test(
    'controller maps and source/network origin declarations are closed data',
    () {
      for (final controls in [
        {'A': 'alert(1)'},
        {'B': 'Escape'},
        {'UP': 'ArrowUp\n'},
      ]) {
        final json = webGameJson();
        json['controls'] = controls;
        expect(() => VrlzWebGameManifest.fromJson(json), throwsFormatException);
      }
      for (final origin in [
        'https://example.org/path',
        'http://example.org',
        'https://*.example.org',
        'https://u:p@example.org',
      ]) {
        final json = webGameJson();
        json['networkOrigins'] = [origin];
        expect(() => VrlzWebGameManifest.fromJson(json), throwsFormatException);
      }
      final json = webGameJson();
      json['networkOrigins'] = ['https://lichess.org'];
      expect(
        VrlzWebGameManifest.fromJson(json).networkOrigins.single.origin,
        'https://lichess.org',
      );
      for (final field in ['sourceUrl', 'licenseUrl', 'sourceArchiveUrl']) {
        final invalid = webGameJson();
        invalid[field] = 'http://example.org/no';
        expect(
          () => VrlzWebGameManifest.fromJson(invalid),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'downloads startup then only requested area; repeated visits use verified cache',
    () async {
      final files = webGameFiles(), requests = <String>[];
      final client = _Client((request) async {
        expect(request.followRedirects, isFalse);
        final path = request.url.path.substring('/build-123/'.length);
        requests.add(path);
        return http.StreamedResponse(Stream.value(files[path]!), 200);
      });
      final loader = VrlzWebGameLoader(
        VrlzWebGameManifest.fromJson(webGameJson()),
        client: client,
      );
      addTearDown(loader.close);
      await loader.prefetchStartup();
      expect(requests, ['index.html', 'main.js']);
      expect(await loader.isUnitCached('first_area'), isFalse);
      await loader.prefetchUnit('first_area');
      expect(requests.last, 'maps/one.json');
      final bytes = await loader.readFile('maps/one.json');
      bytes[0] = 0;
      expect(await loader.readFile('maps/one.json'), files['maps/one.json']);
      expect(requests, hasLength(3));
      expect(requests, isNot(contains('maps/two.json')));
      expect(() => loader.readFile('maps/missing.json'), throwsFormatException);
    },
  );

  test(
    'coalesces simultaneous same-file requests and copies their results',
    () async {
      final files = webGameFiles(),
          response = Completer<http.StreamedResponse>();
      final client = _Client((_) => response.future);
      final loader = VrlzWebGameLoader(
        VrlzWebGameManifest.fromJson(webGameJson()),
        client: client,
      );
      addTearDown(loader.close);
      final a = loader.readFile('main.js'), b = loader.readFile('main.js');
      await Future<void>.delayed(Duration.zero);
      expect(client.sends, 1);
      response.complete(
        http.StreamedResponse(Stream.value(files['main.js']!), 200),
      );
      final first = await a, second = await b;
      first[0] = 0;
      expect(second, files['main.js']);
    },
  );

  test(
    'bad hashes/length/status never enter cache and requests may retry',
    () async {
      for (final kind in ['hash', 'length', 'status']) {
        final files = webGameFiles();
        var calls = 0;
        final client = _Client((_) async {
          calls++;
          final data = calls > 1
              ? files['main.js']!
              : kind == 'hash'
              ? Uint8List(files['main.js']!.length)
              : Uint8List(1);
          return http.StreamedResponse(
            Stream.value(data),
            calls == 1 && kind == 'status' ? 404 : 200,
          );
        });
        final cache = VrlzWebGameMemoryCache();
        final loader = VrlzWebGameLoader(
          VrlzWebGameManifest.fromJson(webGameJson()),
          client: client,
          cache: cache,
        );
        await expectLater(loader.readFile('main.js'), throwsFormatException);
        expect(cache.fileCount, 0);
        expect(await loader.readFile('main.js'), files['main.js']);
        loader.close();
      }
    },
  );

  test('redirect is rejected without a second HTTP request', () async {
    final client = _Client(
      (_) async => http.StreamedResponse(
        const Stream.empty(),
        302,
        headers: {'location': 'https://other.example/main.js'},
      ),
    );
    final loader = VrlzWebGameLoader(
      VrlzWebGameManifest.fromJson(webGameJson()),
      client: client,
    );
    addTearDown(loader.close);
    await expectLater(loader.readFile('main.js'), throwsFormatException);
    expect(client.sends, 1);
  });

  test('development HTTP must be loopback and explicitly enabled', () async {
    final json = webGameJson();
    json['contentBaseUrl'] = 'http://127.0.0.1:8080/build-123/';
    final manifest = VrlzWebGameManifest.fromJson(json);
    expect(() => VrlzWebGameLoader(manifest), throwsFormatException);
    final files = webGameFiles();
    final client = _Client(
      (_) async => http.StreamedResponse(Stream.value(files['main.js']!), 200),
    );
    final loader = VrlzWebGameLoader(
      manifest,
      client: client,
      allowLocalHttp: true,
    );
    addTearDown(loader.close);
    expect(await loader.readFile('main.js'), files['main.js']);
    json['contentBaseUrl'] = 'http://192.168.0.1/build/';
    expect(() => VrlzWebGameManifest.fromJson(json), throwsFormatException);
  });

  test(
    'closing aborts active/queued downloads without closing borrowed client',
    () async {
      final header = Completer<http.StreamedResponse>();
      final client = _Client((_) => header.future);
      final loader = VrlzWebGameLoader(
        VrlzWebGameManifest.fromJson(webGameJson()),
        client: client,
        maxConcurrentDownloads: 1,
      );
      final first = expectLater(loader.readFile('main.js'), throwsStateError);
      final second = expectLater(
        loader.readFile('maps/one.json'),
        throwsStateError,
      );
      await Future<void>.delayed(Duration.zero);
      loader.close();
      await first;
      await second;
      expect(client.closed, isFalse);
      expect(client.sends, 1);
      header.complete(http.StreamedResponse(const Stream.empty(), 200));
    },
  );

  test(
    'memory cache respects byte quota and revisits promote LRU entries',
    () async {
      final files = webGameFiles(),
          manifest = VrlzWebGameManifest.fromJson(webGameJson());
      final a = manifest.file('maps/one.json'),
          b = manifest.file('maps/two.json');
      final main = manifest.file('main.js');
      final cache = VrlzWebGameMemoryCache(
        maxBytes: a.byteLength + b.byteLength + main.byteLength - 1,
      );
      await cache.write(a.sha256, files[a.path]!);
      await cache.write(b.sha256, files[b.path]!);
      await cache.read(a.sha256, byteLength: a.byteLength);
      await cache.write(main.sha256, files[main.path]!);
      expect(cache.byteLength, lessThanOrEqualTo(cache.maxBytes));
      expect(await cache.read(b.sha256, byteLength: b.byteLength), isNull);
      expect(await cache.read(a.sha256, byteLength: a.byteLength), isNotNull);
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
  void close() {
    closed = true;
  }
}
