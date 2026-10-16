import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_apps/vrlizate_apps.dart';

import 'support/vrz_fixture.dart';

void main() {
  test('canonical packer roundtrips metadata, camera and immutable scene', () {
    final scene = triangleGlb();
    final encoded = VrzBundle.encode(
      sceneBytes: scene,
      id: 'org.example.triangle',
      title: 'Triangle',
      cameraPosition: [2, 3, 4],
      cameraTarget: [0, 0, 0],
    );
    final source = Uri.parse('https://example.org/triangle.vrz');
    final bundle = VrzBundle.decode(encoded, source: source);
    expect(bundle.manifest.formatVersion, 1);
    expect(bundle.manifest.entrypointName, 'scene.glb');
    expect(bundle.manifest.cameraPosition, [2, 3, 4]);
    expect(bundle.source, source);
    expect(bundle.sceneBytes, scene);
    encoded.fillRange(0, encoded.length, 0);
    final exposed = bundle.sceneBytes..fillRange(0, scene.length, 0);
    expect(bundle.sceneBytes, scene);
    expect(exposed, isNot(scene));
    expect(() => bundle.manifest.cameraPosition[0] = 5, throwsUnsupportedError);
  });

  test('camera defaults are present when omitted', () {
    final bundle = VrzBundle.decode(fixtureBundle());
    expect(bundle.manifest.cameraPosition, [0, 1.6, 6]);
    expect(bundle.manifest.cameraTarget, [0, 1, -6]);
  });

  final manifestCases = <String, void Function(Map<String, dynamic>)>{
    'future version': (m) => m['formatVersion'] = 2,
    'floating version': (m) => m['formatVersion'] = 1.0,
    'code runtime': (m) => m['runtime'] = 'dart',
    'script entrypoint': (m) => m['entrypoint'] = 'main.js',
    'unknown capability': (m) => m['capabilities'] = ['scene.gltf2', 'network'],
    'duplicate capability': (m) =>
        m['capabilities'] = ['scene.gltf2', 'scene.gltf2'],
    'unknown field': (m) => m['script'] = 'main.dart',
    'missing checksum': (m) => m.remove('sha256'),
    'wrong checksum': (m) => m['sha256'] = {'scene.glb': '0' * 64},
    'unsafe identifier': (m) => m['id'] = '../example',
    'empty title': (m) => m['title'] = ' ',
    'long description': (m) => m['description'] = 'a' * 513,
    'coincident camera': (m) => m['camera'] = {
      'position': [0, 0, 0],
      'target': [0, 0, 0],
    },
    'vertical camera': (m) => m['camera'] = {
      'position': [0, 0, 0],
      'target': [0, 1, 0],
    },
    'oversized camera': (m) => m['camera'] = {
      'position': [10001, 0, 0],
      'target': [0, 0, 0],
    },
    'wrong camera type': (m) => m['camera'] = {
      'position': ['0', 0, 0],
      'target': [1, 0, 0],
    },
  };
  for (final entry in manifestCases.entries) {
    test('rejects manifest ${entry.key}', () {
      expect(
        () => VrzBundle.decode(fixtureBundle(changeManifest: entry.value)),
        throwsFormatException,
      );
    });
  }

  test('rejects corrupted CRC even when manifest content would be valid', () {
    final bytes = fixtureBundle();
    bytes[30 + 'manifest.json'.length + 2] ^= 1;
    expect(() => VrzBundle.decode(bytes), throwsFormatException);
  });

  test('rejects local and central header disagreement', () {
    final bytes = fixtureBundle();
    bytes[14] ^= 1;
    expect(() => VrzBundle.decode(bytes), throwsFormatException);
  });

  for (final name in [
    '../scene.glb',
    '/scene.glb',
    'other.glb',
    'manifest.json',
  ]) {
    test('rejects unknown, unsafe or duplicate ZIP name $name', () {
      final scene = triangleGlb();
      final bytes = storeZip([
        ZipFixtureEntry(
          'manifest.json',
          utf8.encode(jsonEncode(vrzManifest(scene))),
        ),
        ZipFixtureEntry(name, scene),
      ]);
      expect(() => VrzBundle.decode(bytes), throwsFormatException);
    });
  }

  for (final entry in <String, ZipFixtureEntry>{
    'encrypted': ZipFixtureEntry('scene.glb', triangleGlb(), flags: 1),
    'data descriptor': ZipFixtureEntry('scene.glb', triangleGlb(), flags: 8),
    'DEFLATE': ZipFixtureEntry('scene.glb', triangleGlb(), method: 8),
    'symlink': ZipFixtureEntry(
      'scene.glb',
      triangleGlb(),
      attributes: 0xa1ff0000,
    ),
    'directory': ZipFixtureEntry('scene.glb', triangleGlb(), attributes: 0x10),
  }.entries) {
    test('rejects ZIP ${entry.key}', () {
      expect(
        () => VrzBundle.decode(
          storeZip([
            ZipFixtureEntry(
              'manifest.json',
              utf8.encode(jsonEncode(vrzManifest(triangleGlb()))),
            ),
            entry.value,
          ]),
        ),
        throwsFormatException,
      );
    });
  }

  test(
    'rejects truncated archives, appended payload and excessive manifest',
    () {
      final bytes = fixtureBundle();
      for (final value in [
        Uint8List(0),
        Uint8List.sublistView(bytes, 0, bytes.length - 1),
        Uint8List.fromList([...bytes, 0]),
        storeZip([
          ZipFixtureEntry('manifest.json', List.filled(65537, 32)),
          ZipFixtureEntry('scene.glb', triangleGlb()),
        ]),
        Uint8List(VrzBundle.maxBytes + 1),
      ]) {
        expect(() => VrzBundle.decode(value), throwsFormatException);
      }
    },
  );

  final glbCases = <String, void Function(Map<String, dynamic>)>{
    'external buffer': (j) =>
        j['buffers'][0]['uri'] = 'https://example.org/b.bin',
    'data URI': (j) =>
        j['buffers'][0]['uri'] = 'data:application/octet-stream;base64,AA==',
    'embedded image': (j) => j['images'] = [
      {'bufferView': 0, 'mimeType': 'image/png'},
    ],
    'animation': (j) => j['animations'] = [{}],
    'unknown extension': (j) =>
        j['extensionsRequired'] = ['KHR_draco_mesh_compression'],
    'sparse accessor': (j) => j['accessors'][0]['sparse'] = {},
    'accessor outside buffer': (j) => j['accessors'][0]['count'] = 4,
    'illegal component type': (j) => j['accessors'][0]['componentType'] = 1,
    'nontriangle primitive': (j) => j['meshes'][0]['primitives'][0]['mode'] = 1,
    'missing POSITION': (j) =>
        j['meshes'][0]['primitives'][0]['attributes'] = {},
    'invalid material': (j) =>
        j['materials'][0]['pbrMetallicRoughness']['baseColorFactor'] = [
          2,
          0,
          0,
          1,
        ],
    'node cycle': (j) => j['nodes'][0]['children'] = [0],
    'singular TRS scale': (j) => j['nodes'][0]['scale'] = [0, 0, 0],
    'invalid rotation': (j) => j['nodes'][0]['rotation'] = [0, 0, 0, 0],
    'out of range scene root': (j) => j['scenes'][0]['nodes'] = [1],
    'duplicate scene root': (j) => j['scenes'][0]['nodes'] = [0, 0],
    'invalid name type': (j) => j['nodes'][0]['name'] = 17,
  };
  for (final entry in glbCases.entries) {
    test('rejects GLB ${entry.key}', () {
      expect(
        () => VrzBundle.decode(
          fixtureBundle(scene: triangleGlb(changeJson: entry.value)),
        ),
        throwsFormatException,
      );
    });
  }

  test('rejects non-finite geometry and invalid GLB header', () {
    final infinite = triangleGlb(
      changeBinary: (b) => b.setFloat32(0, double.infinity, Endian.little),
    );
    final wrongHeader = triangleGlb()..[0] = 0;
    for (final scene in [infinite, wrongHeader]) {
      expect(
        () => VrzBundle.decode(fixtureBundle(scene: scene)),
        throwsFormatException,
      );
    }
  });

  test('accepts unlit materials within the declared subset', () {
    final scene = triangleGlb(
      changeJson: (j) {
        j['extensionsUsed'] = ['KHR_materials_unlit'];
        j['materials'][0]['extensions'] = {'KHR_materials_unlit': {}};
      },
    );
    expect(VrzBundle.decode(fixtureBundle(scene: scene)).sceneBytes, scene);
  });
}
