import 'dart:convert';
import 'dart:typed_data';

/// A complete GLB with four/two/one triangles and one primitive per LOD.
/// All levels reuse one buffer and one material; no GPU is needed to inspect it.
Uint8List lodGlb({void Function(Map<String, dynamic>)? changeJson}) {
  final binary = Uint8List(144);
  final values = ByteData.sublistView(binary);
  const triangle = [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0];
  for (var i = 0; i < 36; i++) {
    values.setFloat32(i * 4, triangle[i % 9], Endian.little);
  }
  final source = {
    'asset': {'version': '2.0'},
    'buffers': [
      {'byteLength': binary.length},
    ],
    'bufferViews': [
      {'buffer': 0, 'byteLength': binary.length},
    ],
    'accessors': [
      for (final count in [12, 6, 3])
        {
          'bufferView': 0,
          'componentType': 5126,
          'count': count,
          'type': 'VEC3',
        },
    ],
    'materials': [
      {
        'pbrMetallicRoughness': {
          'baseColorFactor': [0.5, 0.6, 0.7, 1],
        },
      },
    ],
    'meshes': [
      for (var i = 0; i < 3; i++)
        {
          'primitives': [
            {
              'attributes': {'POSITION': i},
              'material': 0,
            },
          ],
        },
    ],
    'nodes': [
      for (var i = 0; i < 3; i++)
        {
          'name': 'lod$i',
          'children': [i + 3],
        },
      for (var i = 0; i < 3; i++) {'mesh': i},
    ],
    'scenes': [
      {
        'nodes': [0, 1, 2],
      },
    ],
    'scene': 0,
  };
  final document = jsonDecode(jsonEncode(source)) as Map<String, dynamic>;
  changeJson?.call(document);
  final metadata = utf8.encode(jsonEncode(document));
  final aligned = (metadata.length + 3) & ~3;
  final bytes = Uint8List(28 + aligned + binary.length);
  final header = ByteData.sublistView(bytes);
  header
    ..setUint32(0, 0x46546c67, Endian.little)
    ..setUint32(4, 2, Endian.little)
    ..setUint32(8, bytes.length, Endian.little)
    ..setUint32(12, aligned, Endian.little)
    ..setUint32(16, 0x4e4f534a, Endian.little);
  bytes.fillRange(20, 20 + aligned, 32);
  bytes.setRange(20, 20 + metadata.length, metadata);
  header
    ..setUint32(20 + aligned, binary.length, Endian.little)
    ..setUint32(24 + aligned, 0x004e4942, Endian.little);
  bytes.setRange(28 + aligned, bytes.length, binary);
  return bytes;
}

void addLodBinding(Map<String, dynamic> source) {
  final bindings = (source['prototypeBindings'] as List)
      .map((raw) => Map<String, dynamic>.from(raw as Map))
      .toList();
  source['prototypeBindings'] = bindings;
  final binding = bindings.first;
  binding['lods'] = [
    {'node': 'lod0', 'minDistanceMeters': 0},
    {'node': 'lod1', 'minDistanceMeters': 18},
    {'node': 'lod2', 'minDistanceMeters': 42},
  ];
}
