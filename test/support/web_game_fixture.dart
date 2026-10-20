import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;

Map<String, Uint8List> webGameFiles() => {
  'index.html': Uint8List.fromList(
    utf8.encode(
      '<html><head><base href="./"></head><body><script src="main.js"></script></body></html>',
    ),
  ),
  'main.js': Uint8List.fromList(utf8.encode('window.gameReady=true;')),
  'maps/one.json': Uint8List.fromList(utf8.encode('{"level":1}')),
  'maps/two.json': Uint8List.fromList(utf8.encode('{"level":2}')),
};
Map<String, Object?> webGameJson({Map<String, Uint8List>? files}) {
  final data = files ?? webGameFiles();
  Map<String, Object?> resource(String path) => {
    'path': path,
    'byteLength': data[path]!.length,
    'sha256': '${crypto.sha256.convert(data[path]!)}',
    'mediaType': path.endsWith('.html')
        ? 'text/html'
        : path.endsWith('.js')
        ? 'application/javascript'
        : 'application/json',
  };
  return {
    'formatVersion': 1,
    'runtime': 'vrlizate.webgame.v1',
    'capabilities': ['web.sandbox'],
    'id': 'org.example.webgame',
    'title': 'Verified web game',
    'description': 'Indexed resources',
    'revision': 'commit-123',
    'entrypoint': 'index.html',
    'contentBaseUrl': 'https://games.example/build-123/',
    'controllerProfile': 'dpad',
    'controls': {'A': 'Enter', 'UP': 'ArrowUp'},
    'license': 'MIT',
    'assetNotice': 'Test resources authored for this fixture.',
    'sourceUrl': 'https://github.com/example/game',
    'licenseUrl': 'https://github.com/example/game/blob/123/LICENSE',
    'sourceArchiveUrl': 'https://games.example/source/build-123.zip',
    'units': [
      {
        'id': 'startup',
        'startup': true,
        'files': [resource('index.html'), resource('main.js')],
      },
      {
        'id': 'first_area',
        'startup': false,
        'files': [resource('maps/one.json')],
      },
      {
        'id': 'second_area',
        'startup': false,
        'files': [resource('maps/two.json')],
      },
    ],
  };
}
