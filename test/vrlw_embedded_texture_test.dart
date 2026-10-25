import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter_scene/scene.dart' as fs;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;
import 'package:vrlizate_apps/src/bundles/vrz_glb.dart';
import 'package:vrlizate_apps/src/viewer/vrlw_scene_adapter.dart';
import 'package:vrlizate_apps/vrlizate_apps.dart';
import 'package:vrlizate_world/vrlizate_world.dart';

import 'support/vrlz_world_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'real RGB PNG, repeated float UV0 and trilinear sampler pass world profile',
    () async {
      final bytes = _texturedGlb();
      expect(() => _validate(bytes), returnsNormally);
      expect(() => validateVrzGlb(bytes), throwsFormatException);
      expect(
        () => VrzBundle.encode(
          sceneBytes: bytes,
          id: 'test.scene',
          title: 'Scene',
        ),
        throwsFormatException,
      );
      // Decode the fixture with the platform codec, without creating a GPU scene.
      final codec = await ui.instantiateImageCodec(_rgbPng(2, 2));
      final frame = await codec.getNextFrame();
      expect([frame.image.width, frame.image.height], [2, 2]);
      frame.image.dispose();
      codec.dispose();
    },
  );

  test(
    'a world prepares embedded texture without another resource binding',
    () async {
      final fixture = worldFixture(
        model: _texturedGlb(),
        changeWorld: (source) {
          (source['resources'] as List).removeWhere(
            (r) => r['type'] != 'model.glb',
          );
          source['prototypeBindings'][0].remove('baseColorTexture');
        },
      );
      final bundle = VrlzWorldBundle.decode(
        VrlzWorldBundle.encode(fixture.manifest, fixture.files),
      );
      final prepared = await bundle.openWorld('garden');
      try {
        expect(prepared.resources.keys, ['floor.model']);
        expect(prepared.reader.registeredPrototypeIds, {'test.floor'});
      } finally {
        await prepared.reader.close();
      }
    },
  );

  final invalid = <String, void Function(Map<String, dynamic>)>{
    'external image': (j) =>
        j['images'][0]['uri'] = 'https://example.invalid/a.png',
    'inline URI': (j) => j['images'][0]['uri'] = 'data:image/png;base64,AA==',
    'non-PNG MIME': (j) => j['images'][0]['mimeType'] = 'image/jpeg',
    'image outside views': (j) => j['images'][0]['bufferView'] = 99,
    'strided image': (j) => j['bufferViews'][2]['byteStride'] = 4,
    'out-of-range image view': (j) =>
        j['bufferViews'][2]['byteLength'] = 100000,
    'out-of-range texture source': (j) => j['textures'][0]['source'] = 99,
    'out-of-range texture sampler': (j) => j['textures'][0]['sampler'] = 9,
    'out-of-range material texture': (j) =>
        j['materials'][0]['pbrMetallicRoughness']['baseColorTexture']['index'] =
            9,
    'unsupported UV channel': (j) =>
        j['materials'][0]['pbrMetallicRoughness']['baseColorTexture']['texCoord'] =
            1,
    'fractional UV channel': (j) =>
        j['materials'][0]['pbrMetallicRoughness']['baseColorTexture']['texCoord'] =
            .5,
    'missing UV0': (j) =>
        j['meshes'][0]['primitives'][0]['attributes'].remove('TEXCOORD_0'),
    'UV vertex count mismatch': (j) => j['accessors'][1]['count'] = 2,
    'UV shape mismatch': (j) => j['accessors'][1]['type'] = 'SCALAR',
    'invalid sampler filter': (j) => j['samplers'][0]['minFilter'] = 1234,
    'floating sampler filter': (j) => j['samplers'][0]['minFilter'] = 9987.0,
    'invalid sampler wrap': (j) => j['samplers'][0]['wrapS'] = 1234,
    'normal map is not in embedded subset': (j) =>
        j['materials'][0]['normalTexture'] = {'index': 0},
    'metallic map is not in embedded subset': (j) =>
        j['materials'][0]['pbrMetallicRoughness']['metallicRoughnessTexture'] =
            {'index': 0},
    'emissive map is not in embedded subset': (j) =>
        j['materials'][0]['emissiveTexture'] = {'index': 0},
    'texture transform extension': (j) =>
        j['materials'][0]['pbrMetallicRoughness']['baseColorTexture']['extensions'] =
            {
              'KHR_texture_transform': {
                'scale': [2, 2],
              },
            },
  };
  for (final entry in invalid.entries) {
    test('world rejects ${entry.key} before resource registration', () {
      expect(
        () => _validate(_texturedGlb(changeJson: entry.value)),
        throwsFormatException,
      );
    });
  }

  test(
    'four 256px images fill decoded base-level budget; fifth is rejected',
    () {
      expect(
        () => _validate(_texturedGlb(images: 4, width: 256, height: 256)),
        returnsNormally,
      );
      expect(() => _validate(_texturedGlb(images: 5)), throwsFormatException);
      expect(() => _validate(_texturedGlb(width: 257)), throwsFormatException);
    },
  );

  test(
    'PNG preflight rejects CRC corruption, incomplete image and animation',
    () {
      final png = _rgbPng(2, 2);
      final damaged = Uint8List.fromList(png)..[29] ^= 1;
      final truncated = Uint8List.sublistView(png, 0, png.length - 12);
      final animated = Uint8List.fromList([
        ...png.sublist(0, 33),
        ..._pngChunk('acTL', Uint8List(8)),
        ...png.sublist(33),
      ]);
      for (final bytes in [damaged, truncated, animated]) {
        expect(
          () => _validate(_texturedGlb(png: bytes)),
          throwsFormatException,
        );
      }
      // Resource declarations and embedded images share exactly one PNG parser.
      expect(
        VrlwBundleCodec.validatePngTextureBytes(png, requireComplete: true),
        (width: 2, height: 2),
      );
    },
  );

  test(
    'UV0 accepts normalized unsigned values but rejects raw integers or NaN',
    () {
      expect(
        () => _validate(
          _texturedGlb(
            changeJson: (j) {
              j['accessors'][1]['componentType'] = 5121;
              j['accessors'][1]['normalized'] = true;
            },
          ),
        ),
        returnsNormally,
      );
      expect(
        () => _validate(
          _texturedGlb(
            changeJson: (j) {
              j['accessors'][1]['componentType'] = 5121;
            },
          ),
        ),
        throwsFormatException,
      );
      for (final bad in [double.nan, double.infinity, 4097.0]) {
        expect(
          () => _validate(
            _texturedGlb(
              changeBinary: (data) {
                data.setFloat32(36, bad, Endian.little);
              },
            ),
          ),
          throwsFormatException,
        );
      }
    },
  );

  test('CRC-valid PNG cannot hide corrupt, excessive or invalid scanlines', () {
    final invalidFilter = Uint8List(14)..[0] = 5;
    final badAdler = Uint8List.fromList(ZLibEncoder().encode(Uint8List(14)));
    badAdler[badAdler.length - 1] ^= 1;
    final cases = [
      _rgbPng(2, 2, zlib: Uint8List.fromList([0x78, 0x9c, 0xff, 0, 0, 0, 0])),
      _rgbPng(2, 2, pixels: Uint8List(15)),
      _rgbPng(2, 2, pixels: Uint8List(13)),
      _rgbPng(2, 2, pixels: invalidFilter),
      _rgbPng(2, 2, zlib: badAdler),
    ];
    for (final png in cases) {
      expect(() => _validate(_texturedGlb(png: png)), throwsFormatException);
    }
  });

  test(
    'imported materials and texture sources are shared without GPU copies',
    () {
      final cache = VrlwMaterialCache();
      final texture = _TextureStub(), override = _TextureStub();
      final unlit = fs.UnlitMaterial(colorTexture: texture)
        ..baseColorTextureTexCoord = 0
        ..baseColorTextureTransform = fs.TextureTransform(
          scale: vm.Vector2(3, 4),
        );
      expect(cache.resolve(unlit), same(unlit));
      expect(
        (cache.resolve(unlit) as fs.UnlitMaterial).baseColorTexture,
        same(texture),
      );
      final changed =
          cache.resolve(unlit, baseColor: override) as fs.UnlitMaterial;
      expect(changed.baseColorTexture, same(override));
      expect(cache.resolve(unlit, baseColor: override), same(changed));
      expect(changed.baseColorTextureTransform.scale, vm.Vector2.all(1));
      expect(unlit.baseColorTexture, same(texture));
      expect(unlit.baseColorTextureTransform.scale, vm.Vector2(3, 4));
      final otherMap =
          cache.resolve(unlit, normal: override) as fs.UnlitMaterial;
      expect(otherMap.baseColorTexture, same(texture));
      expect(otherMap.baseColorTextureTransform.scale, vm.Vector2(3, 4));

      final physical = fs.PhysicallyBasedMaterial()
        ..baseColorTexture = texture
        ..normalTexture = texture
        ..normalTextureTransform = fs.TextureTransform(scale: vm.Vector2(5, 6));
      expect(cache.resolve(physical), same(physical));
      final copied =
          cache.resolve(physical, baseColor: override)
              as fs.PhysicallyBasedMaterial;
      expect(copied.baseColorTexture, same(override));
      expect(copied.normalTexture, same(texture));
      expect(copied.normalTextureTransform.scale, vm.Vector2(5, 6));
      expect(cache.resolve(physical, baseColor: override), same(copied));
    },
  );
}

void _validate(Uint8List bytes) => validateVrzGlb(
  bytes,
  maxSubmittedTriangles: 20000,
  allowEmbeddedBaseColorTextures: true,
);

// Texture sources are only referenced in these tests, never sampled/uploaded.
final class _TextureStub implements fs.TextureSource {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('No GPU access');
}

Uint8List _rgbPng(int width, int height, {Uint8List? pixels, Uint8List? zlib}) {
  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8)
    ..setUint8(9, 2);
  final scanlines = pixels ?? Uint8List((width * 3 + 1) * height);
  if (pixels == null) {
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final at = y * (width * 3 + 1) + 1 + x * 3;
        scanlines[at] = 100 + x % 40;
        scanlines[at + 1] = 110 + y % 40;
        scanlines[at + 2] = 120;
      }
    }
  }
  return Uint8List.fromList([
    137,
    80,
    78,
    71,
    13,
    10,
    26,
    10,
    ..._pngChunk('IHDR', header.buffer.asUint8List()),
    ..._pngChunk(
      'IDAT',
      zlib ?? Uint8List.fromList(ZLibEncoder().encode(scanlines)),
    ),
    ..._pngChunk('IEND', Uint8List(0)),
  ]);
}

Uint8List _pngChunk(String type, Uint8List payload) {
  final name = ascii.encode(type);
  final bytes = Uint8List(payload.length + 12);
  ByteData.sublistView(bytes).setUint32(0, payload.length);
  bytes.setRange(4, 8, name);
  bytes.setRange(8, 8 + payload.length, payload);
  ByteData.sublistView(bytes).setUint32(
    payload.length + 8,
    getCrc32(Uint8List.sublistView(bytes, 4, payload.length + 8)),
  );
  return bytes;
}

Uint8List _texturedGlb({
  int images = 1,
  int width = 2,
  int height = 2,
  Uint8List? png,
  void Function(Map<String, dynamic>)? changeJson,
  void Function(ByteData)? changeBinary,
}) {
  final buffer = BytesBuilder(copy: false);
  final geometry = ByteData(60);
  for (final (i, value) in [
    0.0,
    0.0,
    0.0,
    1.0,
    0.0,
    0.0,
    0.0,
    1.0,
    0.0,
    -2.0,
    0.0,
    4.0,
    0.0,
    0.0,
    3.0,
  ].indexed) {
    geometry.setFloat32(i * 4, value, Endian.little);
  }
  changeBinary?.call(geometry);
  buffer.add(geometry.buffer.asUint8List());
  final views = <Map<String, dynamic>>[
    {'buffer': 0, 'byteOffset': 0, 'byteLength': 36},
    {'buffer': 0, 'byteOffset': 36, 'byteLength': 24},
  ];
  for (var i = 0; i < images; i++) {
    final bytes = png ?? _rgbPng(width, height);
    views.add({
      'buffer': 0,
      'byteOffset': buffer.length,
      'byteLength': bytes.length,
    });
    buffer.add(bytes);
    while (buffer.length % 4 != 0) {
      buffer.addByte(0);
    }
  }
  final binary = buffer.takeBytes();
  final root = <String, dynamic>{
    'asset': {'version': '2.0'},
    'buffers': [
      {'byteLength': binary.length},
    ],
    'bufferViews': views,
    'accessors': [
      {'bufferView': 0, 'componentType': 5126, 'count': 3, 'type': 'VEC3'},
      {'bufferView': 1, 'componentType': 5126, 'count': 3, 'type': 'VEC2'},
    ],
    'images': [
      for (var i = 0; i < images; i++)
        {'bufferView': i + 2, 'mimeType': 'image/png'},
    ],
    'textures': [
      for (var i = 0; i < images; i++) {'source': i, 'sampler': 0},
    ],
    'samplers': [
      {'magFilter': 9729, 'minFilter': 9987, 'wrapS': 10497, 'wrapT': 10497},
    ],
    'materials': [
      {
        'pbrMetallicRoughness': {
          'baseColorTexture': {'index': 0, 'texCoord': 0},
        },
      },
    ],
    'meshes': [
      {
        'primitives': [
          {
            'attributes': {'POSITION': 0, 'TEXCOORD_0': 1},
            'material': 0,
          },
        ],
      },
    ],
    'nodes': [
      {'mesh': 0},
    ],
    'scenes': [
      {
        'nodes': [0],
      },
    ],
    'scene': 0,
  };
  final json = jsonDecode(jsonEncode(root)) as Map<String, dynamic>;
  changeJson?.call(json);
  final metadata = utf8.encode(jsonEncode(json));
  final aligned = (metadata.length + 3) & ~3;
  final bytes = Uint8List(28 + aligned + binary.length);
  ByteData.sublistView(bytes)
    ..setUint32(0, 0x46546c67, Endian.little)
    ..setUint32(4, 2, Endian.little)
    ..setUint32(8, bytes.length, Endian.little)
    ..setUint32(12, aligned, Endian.little)
    ..setUint32(16, 0x4e4f534a, Endian.little)
    ..setUint32(20 + aligned, binary.length, Endian.little)
    ..setUint32(24 + aligned, 0x004e4942, Endian.little);
  bytes.fillRange(20, 20 + aligned, 32);
  bytes.setRange(20, 20 + metadata.length, metadata);
  bytes.setRange(28 + aligned, bytes.length, binary);
  return bytes;
}
