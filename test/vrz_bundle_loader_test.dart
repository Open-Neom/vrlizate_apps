import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:vrlizate_apps/vrlizate_apps.dart';

import 'support/vrz_fixture.dart';

final _url = Uri.parse('https://example.org/scene.vrz');

void main() {
  test('streams bounded HTTPS bytes and returns the final source', () async {
    final bytes = fixtureBundle();
    final client = _Client((request) async {
      expect(request, isA<http.AbortableRequest>());
      expect(request.followRedirects, isFalse);
      expect(request.url, _url);
      return http.StreamedResponse(
        Stream.fromIterable([bytes.sublist(0, 31), bytes.sublist(31)]),
        200,
        contentLength: bytes.length,
      );
    });
    final loader = VrzBundleLoader(client: client);
    addTearDown(loader.close);
    final bundle = await loader.load(_url);
    expect(bundle.manifest.title, 'Triangle');
    expect(bundle.source, _url);
  });

  for (final url in [
    'http://example.org/scene.vrz',
    'file:///scene.vrz',
    'https://user:password@example.org/scene.vrz',
    'https://example.org/scene.vrz#hidden',
  ]) {
    test('rejects forbidden URI $url before transport', () async {
      final client = _Client((_) => throw StateError('must not send'));
      final loader = VrzBundleLoader(client: client);
      addTearDown(loader.close);
      await expectLater(loader.load(Uri.parse(url)), throwsFormatException);
      expect(client.sends, 0);
    });
  }

  test('validates each redirect and cancels its unused body', () async {
    var canceled = false;
    final redirect = StreamController<List<int>>(
      onCancel: () {
        canceled = true;
      },
    );
    final client = _Client((request) async {
      if (request.url == _url) {
        return http.StreamedResponse(
          redirect.stream,
          302,
          headers: {'location': '/final.vrz'},
        );
      }
      return http.StreamedResponse(Stream.value(fixtureBundle()), 200);
    });
    final loader = VrzBundleLoader(client: client);
    addTearDown(loader.close);
    final bundle = await loader.load(_url);
    expect(canceled, isTrue);
    expect(client.sends, 2);
    expect(bundle.source, Uri.parse('https://example.org/final.vrz'));
  });

  for (final location in [
    null,
    'http://example.org/scene.vrz',
    'https://user:pass@example.org/scene.vrz',
  ]) {
    test('rejects absent or unsafe redirect $location', () async {
      final client = _Client(
        (_) async => http.StreamedResponse(
          const Stream.empty(),
          302,
          headers: location == null ? {} : {'location': location},
        ),
      );
      final loader = VrzBundleLoader(client: client);
      addTearDown(loader.close);
      await expectLater(loader.load(_url), throwsFormatException);
      expect(client.sends, 1);
    });
  }

  test('stops a redirect loop after three redirects', () async {
    final client = _Client(
      (_) async => http.StreamedResponse(
        const Stream.empty(),
        307,
        headers: {'location': '/scene.vrz'},
      ),
    );
    final loader = VrzBundleLoader(client: client);
    addTearDown(loader.close);
    await expectLater(loader.load(_url), throwsFormatException);
    expect(client.sends, 4);
  });

  test(
    'rejects error statuses and claimed excessive length without consuming',
    () async {
      for (final status in [404, 200]) {
        var canceled = false;
        final response = StreamController<List<int>>(
          onCancel: () {
            canceled = true;
          },
        );
        final client = _Client(
          (_) async => http.StreamedResponse(
            response.stream,
            status,
            contentLength: status == 200 ? VrzBundle.maxBytes + 1 : null,
          ),
        );
        final loader = VrzBundleLoader(client: client);
        await expectLater(loader.load(_url), throwsFormatException);
        expect(canceled, isTrue);
        loader.close();
      }
    },
  );

  test('bounds the actual stream independently of Content-Length', () async {
    var canceled = false;
    final response = StreamController<List<int>>(
      onCancel: () {
        canceled = true;
      },
    );
    final client = _Client(
      (_) async => http.StreamedResponse(response.stream, 200),
    );
    final loader = VrzBundleLoader(client: client, maxDownloadBytes: 8);
    addTearDown(loader.close);
    final pending = expectLater(loader.load(_url), throwsFormatException);
    response.add(List.filled(9, 0));
    await pending;
    expect(canceled, isTrue);
  });

  test('rejects an incomplete declared response', () async {
    final bytes = fixtureBundle();
    final client = _Client(
      (_) async => http.StreamedResponse(
        Stream.value(bytes),
        200,
        contentLength: bytes.length + 1,
      ),
    );
    final loader = VrzBundleLoader(client: client);
    addTearDown(loader.close);
    await expectLater(loader.load(_url), throwsFormatException);
  });

  test(
    'reports network stream failures and cancels its subscription',
    () async {
      final client = _Client(
        (_) async => http.StreamedResponse(
          Stream.error(http.ClientException('Disconnected')),
          200,
        ),
      );
      final loader = VrzBundleLoader(client: client);
      addTearDown(loader.close);
      await expectLater(
        loader.load(_url),
        throwsA(isA<http.ClientException>()),
      );
    },
  );

  test(
    'deadline applies while waiting for headers and aborts request',
    () async {
      final headers = Completer<http.StreamedResponse>();
      var aborted = false;
      final client = _Client((request) {
        (request as http.AbortableRequest).abortTrigger!.then((_) {
          aborted = true;
        });
        return headers.future;
      });
      final loader = VrzBundleLoader(
        client: client,
        timeout: const Duration(milliseconds: 10),
      );
      addTearDown(loader.close);
      await expectLater(loader.load(_url), throwsA(isA<TimeoutException>()));
      expect(aborted, isTrue);
      // A borrowed client may deliver late headers despite the abort request.
      var canceled = false;
      final response = StreamController<List<int>>(
        onCancel: () {
          canceled = true;
        },
      );
      headers.complete(http.StreamedResponse(response.stream, 200));
      await Future<void>.delayed(Duration.zero);
      expect(canceled, isTrue);
    },
  );

  test('deadline cancels a stalled body stream', () async {
    var canceled = false;
    final response = StreamController<List<int>>(
      onCancel: () {
        canceled = true;
      },
    );
    final client = _Client(
      (_) async => http.StreamedResponse(response.stream, 200),
    );
    final loader = VrzBundleLoader(
      client: client,
      timeout: const Duration(milliseconds: 10),
    );
    addTearDown(loader.close);
    await expectLater(loader.load(_url), throwsA(isA<TimeoutException>()));
    expect(canceled, isTrue);
  });

  test(
    'deadline also bounds an uncooperative stream cancellation hook',
    () async {
      final never = Completer<void>();
      final response = StreamController<List<int>>(
        onCancel: () => never.future,
      );
      final client = _Client(
        (_) async => http.StreamedResponse(response.stream, 200),
      );
      final loader = VrzBundleLoader(
        client: client,
        timeout: const Duration(milliseconds: 10),
      );
      addTearDown(loader.close);
      await expectLater(loader.load(_url), throwsA(isA<TimeoutException>()));
      never.complete();
    },
  );

  test(
    'close aborts active loads, is idempotent and preserves borrowed clients',
    () async {
      final response = StreamController<List<int>>();
      final client = _Client(
        (_) async => http.StreamedResponse(response.stream, 200),
      );
      final loader = VrzBundleLoader(client: client);
      final pending = expectLater(loader.load(_url), throwsStateError);
      loader.close();
      loader.close();
      await pending;
      await expectLater(loader.load(_url), throwsStateError);
      expect(client.closed, isFalse);
    },
  );
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
  void close() {
    closed = true;
  }
}
