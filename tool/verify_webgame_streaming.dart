import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:vrlizate_apps/vrlizate_apps.dart';
import 'package:vrlizate_apps/vrlizate_apps_io.dart';

/// Exercises real packaged resources over HTTP, then reopens the same content
/// offline. No browser/gameplay or device performance claim is made here.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    throw ArgumentError('Pass a local .vrlz descriptor.');
  }
  final package = VrlzPackage.decode(
    await File(arguments.single).readAsBytes(),
  );
  final manifest = package.webGameManifest!;
  final directory = await Directory.systemTemp.createTemp(
    'vrlizate-stream-qa-',
  );
  final client = _Client();
  final cache = VrlzWebGameFileCache(
    directory.path,
    maxBytes: 128 * 1024 * 1024,
  );
  final loader = VrlzWebGameLoader(
    manifest,
    client: client,
    cache: cache,
    allowLocalHttp: true,
  );
  try {
    await loader.prefetchStartup();
    final initial = client.urls.length;
    final units = manifest.units
        .where((unit) => !unit.startup && unit.files.isNotEmpty)
        .toList();
    final selected = units.first.files.first;
    final bytes = await loader.readFile(selected.path);
    if (client.urls.length != initial + 1) {
      throw StateError('Unexpected resource download count.');
    }
    await loader.readFile(selected.path);
    if (client.urls.length != initial + 1) {
      throw StateError('Cached resource was downloaded again.');
    }
    final unavailable = units
        .expand((unit) => unit.files)
        .where(
          (file) =>
              file.path != selected.path && file.sha256 != selected.sha256,
        )
        .first;
    if (await cache.read(
          unavailable.sha256,
          byteLength: unavailable.byteLength,
        ) !=
        null) {
      throw StateError('Unvisited resource was unexpectedly downloaded.');
    }
    loader.close();
    client.offline = true;
    final offline = VrlzWebGameLoader(
      manifest,
      client: client,
      cache: VrlzWebGameFileCache(directory.path, maxBytes: 128 * 1024 * 1024),
      allowLocalHttp: true,
    );
    try {
      final reopened = await offline.readFile(selected.path);
      if (reopened.length != bytes.length || client.urls.length != initial + 1) {
        throw StateError('Offline cache failed.');
      }
    } finally {
      offline.close();
    }
    stdout.writeln(
      '${manifest.id}: PASS startup=$initial requests, selected=${selected.path}, '
      'unvisited=${unavailable.path}, persistent offline hit; full content ${manifest.byteLength} bytes was not downloaded.',
    );
  } finally {
    loader.close();
    client.close();
    await directory.delete(recursive: true);
  }
}

class _Client extends http.BaseClient {
  final _delegate = http.Client();
  final urls = <Uri>[];
  bool offline = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (offline) throw const SocketException('Offline verification');
    urls.add(request.url);
    return _delegate.send(request);
  }

  @override
  void close() => _delegate.close();
}
