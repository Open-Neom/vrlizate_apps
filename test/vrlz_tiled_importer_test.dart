import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_apps/vrlizate_apps.dart';

Map<String, Object?> fixtureMap() => {
  'type': 'map',
  'orientation': 'orthogonal',
  'infinite': false,
  'width': 16,
  'height': 8,
  'tilewidth': 16,
  'tileheight': 16,
  'tilesets': [
    {'firstgid': 1, 'tilecount': 1, 'name': 'solid'},
  ],
  'layers': [
    {
      'name': 'terrain',
      'type': 'tilelayer',
      'width': 16,
      'height': 8,
      'data': List.generate(128, (i) => i >= 112 ? 1 : 0),
    },
    {
      'name': 'entities',
      'type': 'objectgroup',
      'objects': [
        {'point': true, 'type': 'spawn', 'x': 32, 'y': 96},
        {'point': true, 'class': 'exit', 'x': 208, 'y': 96},
        {'point': true, 'name': 'gem', 'x': 80, 'y': 96},
        {'point': true, 'class': 'enemy', 'x': 96, 'y': 96},
        {'point': true, 'class': 'boss', 'x': 112, 'y': 96},
        {'point': true, 'class': 'checkpoint', 'x': 128, 'y': 96},
        {'point': true, 'class': 'spike', 'x': 144, 'y': 96},
      ],
    },
  ],
};

VrlzRetroLevel import(Map<String, Object?> map) =>
    VrlzTiledImporter.importLevel(
      map,
      name: 'Original map',
      theme: 'neon',
      mode: 'blaster',
    );

void main() {
  test(
    'finite orthogonal Tiled terrain and point entities become exact tiles',
    () {
      final map = fixtureMap();
      final terrain = (map['layers'] as List).first as Map;
      terrain['encoding'] = 'csv';
      terrain['compression'] = '';
      final level = import(map);
      expect(level.rows[6], '..S..*EBK^...G..');
      expect(level.rows[7], '################');
      expect(level.name, 'Original map');
      expect(level.theme, 'neon');
      expect(level.mode, 'blaster');
    },
  );

  final bad = <String, void Function(Map<String, dynamic>)>{
    'infinite': (m) => m['infinite'] = true,
    'isometric': (m) => m['orientation'] = 'isometric',
    'zero tile size': (m) => m['tilewidth'] = 0,
    'oversize tile size': (m) => m['tileheight'] = 257,
    'large map': (m) => m['width'] = 129,
    'external tileset': (m) => m['tilesets'][0]['source'] = '../tiles.tsx',
    'multiple tiles': (m) => m['tilesets'][0]['tilecount'] = 2,
    'flipped GID': (m) => m['layers'][0]['data'][0] = 0x80000001,
    'unrecognized GID': (m) => m['layers'][0]['data'][0] = 2,
    'floating GID': (m) => m['layers'][0]['data'][0] = 1.0,
    'short terrain': (m) => m['layers'][0]['data'].removeLast(),
    'compression': (m) => m['layers'][0]['compression'] = 'zlib',
    'encoding': (m) => m['layers'][0]['encoding'] = 'base64',
    'chunks': (m) => m['layers'][0]['chunks'] = [],
    'offset': (m) => m['layers'][0]['offsetx'] = 16,
    'hidden layer': (m) => m['layers'][1]['visible'] = false,
    'unknown layer': (m) => m['layers'][1]['name'] = 'logic',
    'external template': (m) =>
        m['layers'][1]['objects'][0]['template'] = 'player.tx',
    'tile entity': (m) => m['layers'][1]['objects'][0]['gid'] = 1,
    'non point': (m) => m['layers'][1]['objects'][0]['point'] = false,
    'unknown class': (m) => m['layers'][1]['objects'][0]['class'] = 'script',
    'off grid': (m) => m['layers'][1]['objects'][0]['x'] = 33,
    'negative position': (m) => m['layers'][1]['objects'][0]['x'] = -16,
    'out of bounds': (m) => m['layers'][1]['objects'][0]['x'] = 256,
    'overlap terrain': (m) => m['layers'][1]['objects'][0]['y'] = 112,
    'overlap entity': (m) =>
        m['layers'][1]['objects'][1] = m['layers'][1]['objects'][0],
  };
  for (final entry in bad.entries) {
    test('Tiled rejects ${entry.key}', () {
      final json = jsonDecode(jsonEncode(fixtureMap())) as Map<String, dynamic>;
      entry.value(json);
      expect(() => import(json), throwsFormatException);
    });
  }
}
