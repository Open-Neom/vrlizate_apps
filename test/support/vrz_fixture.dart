import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

Uint8List triangleGlb({
  void Function(Map<String, dynamic>)? changeJson,
  void Function(ByteData)? changeBinary,
}) {
  final binary = Uint8List(36);
  final numbers = ByteData.sublistView(binary);
  final positions = [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0];
  for (var i = 0; i < positions.length; i++) {
    numbers.setFloat32(i * 4, positions[i], Endian.little);
  }
  changeBinary?.call(numbers);
  final json = <String, dynamic>{
    'asset': {'version': '2.0'},
    'buffers': [
      {'byteLength': binary.length},
    ],
    'bufferViews': [
      {'buffer': 0, 'byteOffset': 0, 'byteLength': binary.length},
    ],
    'accessors': [
      {'bufferView': 0, 'componentType': 5126, 'count': 3, 'type': 'VEC3'},
    ],
    'materials': [
      {
        'pbrMetallicRoughness': {
          'baseColorFactor': [0.5, 0.6, 0.7, 1],
        },
      },
    ],
    'meshes': [
      {
        'primitives': [
          {
            'attributes': {'POSITION': 0},
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
  // JSON decoding gives every nested map dynamic values, so adversarial
  // mutations test the validator instead of inferred literal generic types.
  final mutableJson = jsonDecode(jsonEncode(json)) as Map<String, dynamic>;
  changeJson?.call(mutableJson);
  final metadata = utf8.encode(jsonEncode(mutableJson));
  final aligned = (metadata.length + 3) & ~3;
  final bytes = Uint8List(12 + 8 + aligned + 8 + binary.length);
  final data = ByteData.sublistView(bytes);
  data.setUint32(0, 0x46546c67, Endian.little);
  data.setUint32(4, 2, Endian.little);
  data.setUint32(8, bytes.length, Endian.little);
  data.setUint32(12, aligned, Endian.little);
  data.setUint32(16, 0x4e4f534a, Endian.little);
  bytes.fillRange(20, 20 + aligned, 32);
  bytes.setRange(20, 20 + metadata.length, metadata);
  data.setUint32(20 + aligned, binary.length, Endian.little);
  data.setUint32(24 + aligned, 0x004e4942, Endian.little);
  bytes.setRange(28 + aligned, bytes.length, binary);
  return bytes;
}

Map<String, dynamic> vrzManifest(Uint8List scene) => {
  'formatVersion': 1,
  'id': 'org.example.triangle',
  'title': 'Triangle',
  'description': 'A test scene.',
  'runtime': 'vrlizate.scene.v1',
  'entrypoint': 'scene.glb',
  'capabilities': ['scene.gltf2'],
  'sha256': {'scene.glb': sha256.convert(scene).toString()},
};

Uint8List fixtureBundle({
  Uint8List? scene,
  void Function(Map<String, dynamic>)? changeManifest,
}) {
  final glb = scene ?? triangleGlb();
  final manifest = vrzManifest(glb);
  changeManifest?.call(manifest);
  return storeZip([
    ZipFixtureEntry('manifest.json', utf8.encode(jsonEncode(manifest))),
    ZipFixtureEntry('scene.glb', glb),
  ]);
}

Map<String, dynamic> vrlzBuiltinManifest() => {
  'formatVersion': 2,
  'id': 'org.example.room',
  'title': 'Cuarto integrado',
  'description': 'Abre una demo que el anfitrión ya contiene.',
  'runtime': 'vrlizate.builtin.v1',
  'entrypoint': 'flutter_scene_room',
  'capabilities': ['host.builtin'],
  'sha256': <String, String>{},
};

Uint8List fixtureBuiltin({
  void Function(Map<String, dynamic>)? changeManifest,
  List<ZipFixtureEntry> extraEntries = const [],
}) {
  final manifest = vrlzBuiltinManifest();
  changeManifest?.call(manifest);
  return storeZip([
    ZipFixtureEntry('manifest.json', utf8.encode(jsonEncode(manifest))),
    ...extraEntries,
  ]);
}

/// Independent writer allows deliberately invalid names and duplicate entries.
class ZipFixtureEntry {
  ZipFixtureEntry(
    this.name,
    this.bytes, {
    this.flags = 0,
    this.method = 0,
    this.attributes = 0,
  });
  final String name;
  final List<int> bytes;
  final int flags;
  final int method;
  final int attributes;
}

Uint8List storeZip(List<ZipFixtureEntry> entries) {
  final locals = BytesBuilder();
  final centrals = BytesBuilder();
  for (final entry in entries) {
    final name = utf8.encode(entry.name);
    final crc = getCrc32(entry.bytes);
    final local = Uint8List(30);
    final l = ByteData.sublistView(local);
    l.setUint32(0, 0x04034b50, Endian.little);
    l.setUint16(4, 20, Endian.little);
    l.setUint16(6, entry.flags, Endian.little);
    l.setUint16(8, entry.method, Endian.little);
    l.setUint32(14, crc, Endian.little);
    l.setUint32(18, entry.bytes.length, Endian.little);
    l.setUint32(22, entry.bytes.length, Endian.little);
    l.setUint16(26, name.length, Endian.little);
    final central = Uint8List(46);
    final c = ByteData.sublistView(central);
    c.setUint32(0, 0x02014b50, Endian.little);
    c.setUint16(4, 0x0314, Endian.little);
    c.setUint16(6, 20, Endian.little);
    c.setUint16(8, entry.flags, Endian.little);
    c.setUint16(10, entry.method, Endian.little);
    c.setUint32(16, crc, Endian.little);
    c.setUint32(20, entry.bytes.length, Endian.little);
    c.setUint32(24, entry.bytes.length, Endian.little);
    c.setUint16(28, name.length, Endian.little);
    c.setUint32(38, entry.attributes, Endian.little);
    c.setUint32(42, locals.length, Endian.little);
    locals
      ..add(local)
      ..add(name)
      ..add(entry.bytes);
    centrals
      ..add(central)
      ..add(name);
  }
  final end = Uint8List(22);
  final e = ByteData.sublistView(end);
  e.setUint32(0, 0x06054b50, Endian.little);
  e.setUint16(8, entries.length, Endian.little);
  e.setUint16(10, entries.length, Endian.little);
  e.setUint32(12, centrals.length, Endian.little);
  e.setUint32(16, locals.length, Endian.little);
  return (BytesBuilder()
        ..add(locals.takeBytes())
        ..add(centrals.takeBytes())
        ..add(end))
      .takeBytes();
}
