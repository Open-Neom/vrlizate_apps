import '../bundles/vrlz_retro_level.dart';

/// Imports a deliberately small subset of Tiled's finite orthogonal JSON.
/// Terrain is a flat numeric tile layer (0 empty, 1 solid). Entities are point
/// objects at grid intersections in an `entities` object layer; their class,
/// type or name is spawn/exit/gem/enemy/boss/checkpoint/spike. Image loading, scripts,
/// external tilesets/templates, compression and arbitrary GIDs are unsupported.
final class VrlzTiledImporter {
  const VrlzTiledImporter._();

  static VrlzRetroLevel importLevel(
    Map<String, Object?> json, {
    required String name,
    required String theme,
    required String mode,
  }) {
    final width = json['width'];
    final height = json['height'];
    final tileWidth = json['tilewidth'];
    final tileHeight = json['tileheight'];
    if (json['type'] != 'map' ||
        json['orientation'] != 'orthogonal' ||
        json['infinite'] != false ||
        width is! int ||
        width < 16 ||
        width > 128 ||
        height is! int ||
        height < 8 ||
        height > 24 ||
        tileWidth is! int ||
        tileWidth < 1 ||
        tileWidth > 256 ||
        tileHeight is! int ||
        tileHeight < 1 ||
        tileHeight > 256) {
      throw const FormatException(
        'Tiled requires a finite, bounded orthogonal map.',
      );
    }
    final tilesets = json['tilesets'];
    if (tilesets is! List || tilesets.length != 1 || tilesets.single is! Map) {
      throw const FormatException(
        'Tiled requires one embedded single-tile tileset.',
      );
    }
    final tileset = tilesets.single as Map;
    if (tileset.containsKey('source') ||
        tileset['firstgid'] != 1 ||
        tileset['tilecount'] != 1) {
      throw const FormatException(
        'External tilesets and multi-tile GIDs are unsupported.',
      );
    }
    final layers = json['layers'];
    if (layers is! List ||
        layers.length != 2 ||
        layers.any((layer) => layer is! Map)) {
      throw const FormatException(
        'Tiled requires exactly terrain and entities layers.',
      );
    }
    Map? terrain;
    Map? entities;
    for (final raw in layers) {
      final layer = raw as Map;
      if ((layer['x'] ?? 0) != 0 ||
          (layer['y'] ?? 0) != 0 ||
          (layer['offsetx'] ?? 0) != 0 ||
          (layer['offsety'] ?? 0) != 0 ||
          (layer['visible'] ?? true) != true ||
          (layer['opacity'] ?? 1) != 1 ||
          layer.containsKey('chunks') ||
          (layer['compression'] ?? '') != '' ||
          (layer['encoding'] ?? 'csv') != 'csv') {
        throw const FormatException(
          'Tiled layer offsets, hidden data and encodings are unsupported.',
        );
      }
      if (layer['name'] == 'terrain' &&
          layer['type'] == 'tilelayer' &&
          terrain == null) {
        terrain = layer;
      } else if (layer['name'] == 'entities' &&
          layer['type'] == 'objectgroup' &&
          entities == null) {
        entities = layer;
      } else {
        throw const FormatException('Unsupported or duplicate Tiled layer.');
      }
    }
    final data = terrain?['data'];
    final objects = entities?['objects'];
    if (terrain?['width'] != width ||
        terrain?['height'] != height ||
        data is! List ||
        data.length != width * height ||
        data.any((gid) => gid is! int || (gid != 0 && gid != 1)) ||
        objects is! List ||
        objects.length > 1024) {
      throw const FormatException(
        'Invalid Tiled terrain or entity collection.',
      );
    }
    final rows = List.generate(
      height,
      (row) => List.generate(
        width,
        (column) => data[row * width + column] == 1 ? '#' : '.',
      ),
    );
    const symbols = {
      'spawn': 'S',
      'exit': 'G',
      'gem': '*',
      'enemy': 'E',
      'boss': 'B',
      'checkpoint': 'K',
      'spike': '^',
    };
    for (final object in objects) {
      if (object is! Map ||
          object['point'] != true ||
          object.containsKey('template') ||
          object.containsKey('gid') ||
          (object['rotation'] ?? 0) != 0 ||
          (object['width'] ?? 0) != 0 ||
          (object['height'] ?? 0) != 0 ||
          (object['visible'] ?? true) != true) {
        throw const FormatException(
          'Tiled entities must be visible, unrotated point objects.',
        );
      }
      String? entityName;
      for (final key in ['class', 'type', 'name']) {
        final value = object[key];
        if (value is String && value.isNotEmpty) {
          entityName = value;
          break;
        }
      }
      final symbol = symbols[entityName];
      final x = object['x'];
      final y = object['y'];
      if (symbol == null ||
          x is! num ||
          y is! num ||
          !x.isFinite ||
          !y.isFinite ||
          x < 0 ||
          y < 0 ||
          x >= width * tileWidth ||
          y >= height * tileHeight ||
          x % tileWidth != 0 ||
          y % tileHeight != 0) {
        throw const FormatException(
          'Unknown Tiled entity or position outside its tile grid.',
        );
      }
      final column = x ~/ tileWidth;
      final row = y ~/ tileHeight;
      if (rows[row][column] != '.') {
        throw const FormatException(
          'Tiled entities cannot overlap terrain or another entity.',
        );
      }
      rows[row][column] = symbol;
    }
    return VrlzRetroLevel.fromJson({
      'name': name,
      'theme': theme,
      'mode': mode,
      'rows': rows.map((row) => row.join()).toList(),
    });
  }
}
