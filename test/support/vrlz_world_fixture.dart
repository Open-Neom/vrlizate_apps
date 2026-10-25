import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:vrlizate_apps/vrlizate_apps.dart';
import 'package:vrlizate_apps/src/bundles/vrz_zip.dart';
import 'package:vrlizate_world/vrlizate_world.dart';

import 'vrz_fixture.dart';

({Map<String, dynamic> manifest, Map<String, Uint8List> files}) worldFixture({
  Uint8List? model,
  void Function(Map<String, dynamic>)? changeWorld,
  List<String> worldAliases = const ['garden', 'gallery'],
}) {
  final worlds = <Map<String, dynamic>>[];
  final files = <String, Uint8List>{};
  for (final alias in worldAliases) {
    final source = <String, dynamic>{
      'schemaVersion': 1,
      'id': 'test.$alias',
      'title': alias,
      'revision': '1.0.0',
      'license': 'CC0-1.0',
      'gridId': 'test-$alias',
      'cellSizeMeters': 12,
      'origin': {'type': 'local'},
      'prototypes': ['test.floor'],
      'regions': [
        {
          'x': 0,
          'z': 0,
          'entities': [
            {
              'id': 'floor',
              'prototypeId': 'test.floor',
              'x': 1,
              'y': 0,
              'z': 1,
            },
          ],
        },
      ],
      'resources': [
        {
          'id': 'floor.model',
          'type': 'model.glb',
          'data': base64Encode(model ?? triangleGlb()),
        },
        {
          'id': 'floor.color',
          'type': 'texture.rgba8',
          'width': 1,
          'height': 1,
          'data': base64Encode([255, 255, 255, 255]),
        },
      ],
      'prototypeBindings': [
        {
          'prototypeId': 'test.floor',
          'model': 'floor.model',
          'baseColorTexture': 'floor.color',
        },
      ],
    };
    changeWorld?.call(source);
    final bytes = VrlwBundleCodec.encode(source);
    final header = VrlwBundleCodec.parseHeader(bytes.sublist(0, 16));
    final index = VrlwBundleCodec.parseIndex(
      header,
      bytes.sublist(16, header.payloadOffset),
    );
    final file = 'world_$alias.vrlw';
    files[file] = bytes;
    worlds.add({
      'alias': alias,
      'id': index.id,
      'file': file,
      'sha256': sha256.convert(bytes).toString(),
      'indexSha256': index.indexSha256,
      'spawn': [2, 1.6, 2],
      'yaw': 0,
    });
  }
  return (
    manifest: {
      'formatVersion': 1,
      'id': 'test.experience',
      'title': 'Two connected worlds',
      'description': 'Portable test',
      'runtime': VrlzWorldManifest.runtime,
      'entrypoint': 'garden',
      'capabilities': ['worlds.local'],
      'revision': '1.0.0',
      'worlds': worlds,
      'portals': [
        {
          'id': 'to_gallery',
          'from': 'garden',
          'to': 'gallery',
          'position': [3, 1.6, 2],
          'arrival': [4, 1.6, 4],
          'yaw': 1,
          'label': 'Gallery',
        },
        {
          'id': 'to_garden',
          'from': 'gallery',
          'to': 'garden',
          'position': [4, 1.6, 4],
          'arrival': [5, 1.6, 5],
          'yaw': 2,
          'label': 'Garden',
        },
      ],
    },
    files: files,
  );
}

Uint8List fixtureWorlds() {
  final fixture = worldFixture();
  return VrlzWorldBundle.encode(fixture.manifest, fixture.files);
}

Uint8List uncheckedWorldArchive(
  Map<String, dynamic> manifest,
  Map<String, Uint8List> files,
) {
  final data = utf8.encode(jsonEncode(manifest));
  return writeVrzStoreZip(
    {'manifest.json': Uint8List.fromList(data), ...files},
    VrlzWorldBundle.maxBytes,
    maxEntries: files.length + 1,
  );
}
