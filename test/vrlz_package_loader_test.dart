import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:vrlizate_apps/vrlizate_apps.dart';

import 'support/vrz_fixture.dart';

void main() {
  final url = Uri.parse('https://example.org/room.vrlz');

  test(
    'loads builtin metadata over bounded HTTPS with final redirect source',
    () async {
      final bytes = fixtureBuiltin();
      final client = _Client((request) async {
        expect(request, isA<http.AbortableRequest>());
        expect(request.followRedirects, isFalse);
        if (request.url == url) {
          return http.StreamedResponse(
            const Stream.empty(),
            302,
            headers: {'location': '/published/room.vrlz'},
          );
        }
        return http.StreamedResponse(
          Stream.fromIterable([bytes.sublist(0, 10), bytes.sublist(10)]),
          200,
          contentLength: bytes.length,
        );
      });
      final loader = VrlzPackageLoader(client: client);
      addTearDown(loader.close);
      final package = await loader.load(url);
      expect(package.kind, VrlzPackageKind.builtin);
      expect(package.demoId, 'flutter_scene_room');
      expect(
        package.source,
        Uri.parse('https://example.org/published/room.vrlz'),
      );
      expect(VrlzPackage.decode(package.encode()).id, package.id);
      expect(client.sends, 2);
    },
  );

  test(
    'new loader accepts legacy scenes and old loader stays scene-only',
    () async {
      final scenes = _Client(
        (_) async => http.StreamedResponse(Stream.value(fixtureBundle()), 200),
      );
      final packages = VrlzPackageLoader(client: scenes);
      addTearDown(packages.close);
      expect((await packages.load(url)).kind, VrlzPackageKind.scene);
      final descriptors = _Client(
        (_) async => http.StreamedResponse(Stream.value(fixtureBuiltin()), 200),
      );
      final legacy = VrzBundleLoader(client: descriptors);
      addTearDown(legacy.close);
      await expectLater(legacy.load(url), throwsFormatException);
    },
  );

  test(
    'new loader rejects malformed bytes without a builtin fallback',
    () async {
      final bytes = fixtureBundle(
        changeManifest: (manifest) =>
            manifest['sha256'] = {'scene.glb': '0' * 64},
      );
      final client = _Client(
        (_) async => http.StreamedResponse(Stream.value(bytes), 200),
      );
      final loader = VrlzPackageLoader(client: client);
      addTearDown(loader.close);
      await expectLater(loader.load(url), throwsFormatException);
    },
  );

  test(
    'new loader applies actual byte budget and cancels the stream',
    () async {
      var canceled = false;
      final response = StreamController<List<int>>(
        onCancel: () => canceled = true,
      );
      final client = _Client(
        (_) async => http.StreamedResponse(response.stream, 200),
      );
      final loader = VrlzPackageLoader(client: client, maxDownloadBytes: 8);
      addTearDown(loader.close);
      final failure = expectLater(loader.load(url), throwsFormatException);
      response.add(List.filled(9, 0));
      await failure;
      expect(canceled, isTrue);
    },
  );

  test(
    'new loader closes pending requests without owning an injected client',
    () async {
      final headers = Completer<http.StreamedResponse>();
      var aborted = false;
      final client = _Client((request) {
        (request as http.AbortableRequest).abortTrigger!.then(
          (_) => aborted = true,
        );
        return headers.future;
      });
      final loader = VrlzPackageLoader(client: client);
      final failure = expectLater(loader.load(url), throwsStateError);
      loader.close();
      loader.close();
      await failure;
      expect(aborted, isTrue);
      expect(client.closed, isFalse);
      await expectLater(loader.load(url), throwsStateError);
      var canceled = false;
      final late = StreamController<List<int>>(onCancel: () => canceled = true);
      headers.complete(http.StreamedResponse(late.stream, 200));
      await Future<void>.delayed(Duration.zero);
      expect(canceled, isTrue);
    },
  );

  test('new loader rejects unsafe URLs before any request', () async {
    final client = _Client((_) => throw StateError('Must not send'));
    final loader = VrlzPackageLoader(client: client);
    addTearDown(loader.close);
    for (final uri in [
      'http://example.org/room.vrlz',
      'https://user:pass@example.org/room.vrlz',
      'https://example.org/room.vrlz#fragment',
      'file:///room.vrlz',
    ]) {
      await expectLater(loader.load(Uri.parse(uri)), throwsFormatException);
    }
    expect(client.sends, 0);
  });
}

class _Client extends http.BaseClient {
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
