import 'dart:convert';
import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart' as vm;
import 'package:vrlizate_world/vrlizate_world.dart';

/// Admission limits for the opt-in, embedded base-color subset of world GLB.
abstract final class VrzGlbTextureLimits {
  static const maxImages = 4;
  static const maxDimension = 256;
  static const maxDecodedBytes = 1024 * 1024;
}

/// The scene subset is intentionally smaller than all of glTF 2.0.
/// Existing VRZ scenes remain texture-free; only portable worlds opt in.
void validateVrzGlb(
  Uint8List bytes, {
  int maxSubmittedTriangles = 250000,
  bool allowEmbeddedBaseColorTextures = false,
}) {
  void fail(String message) => throw FormatException('VRZ GLB: $message');
  if (bytes.length < 28) fail('truncated header');
  final data = ByteData.sublistView(bytes);
  if (data.getUint32(0, Endian.little) != 0x46546c67 ||
      data.getUint32(4, Endian.little) != 2 ||
      data.getUint32(8, Endian.little) != bytes.length) {
    fail('expected a complete GLB version 2 file');
  }
  var offset = 12;
  Map<String, Object?>? root;
  Uint8List? binary;
  var chunks = 0;
  while (offset < bytes.length) {
    if (offset + 8 > bytes.length) fail('truncated chunk');
    final length = data.getUint32(offset, Endian.little);
    final type = data.getUint32(offset + 4, Endian.little);
    offset += 8;
    if (length % 4 != 0 || length > bytes.length - offset) {
      fail('invalid chunk length');
    }
    final content = Uint8List.sublistView(bytes, offset, offset + length);
    if (chunks == 0 && type == 0x4e4f534a && length <= 2 * 1024 * 1024) {
      root = decodeVrzJson(content);
    } else if (chunks == 1 && type == 0x004e4942) {
      binary = content;
    } else {
      fail('only JSON then BIN chunks are supported');
    }
    chunks++;
    offset += length;
  }
  if (chunks != 2 || root == null || binary == null) {
    fail('JSON and BIN chunks are required');
  }
  final json = root!;
  final bin = binary!;
  final asset = _map(json['asset'], 'asset');
  if (asset['version'] != '2.0' ||
      (asset['minVersion'] != null && asset['minVersion'] != '2.0')) {
    fail('unsupported glTF asset version');
  }
  _checkTree(
    json,
    allowEmbeddedBaseColorTextures: allowEmbeddedBaseColorTextures,
  );
  for (final key in [
    if (!allowEmbeddedBaseColorTextures) ...['images', 'textures', 'samplers'],
    'animations',
    'skins',
    'cameras',
  ]) {
    if (_list(json[key], key).isNotEmpty) {
      fail('$key are not supported in version 1');
    }
  }
  for (final key in ['extensionsUsed', 'extensionsRequired']) {
    final extensions = _list(json[key], key);
    if (extensions.toSet().length != extensions.length ||
        extensions.any((value) => value != 'KHR_materials_unlit')) {
      fail('unsupported or duplicate extensions');
    }
  }
  final buffers = _list(json['buffers'], 'buffers');
  if (buffers.length != 1) fail('exactly one embedded buffer is required');
  final buffer = _map(buffers.single, 'buffer');
  final bufferLength = _integer(buffer['byteLength'], 'buffer.byteLength');
  if (bufferLength > bin.length || bin.length - bufferLength > 3) {
    fail('buffer length disagrees with BIN');
  }
  final views = _list(json['bufferViews'], 'bufferViews');
  final accessors = _list(json['accessors'], 'accessors');
  if (views.length > 4096 || accessors.length > 4096) {
    fail('too many buffer views or accessors');
  }
  final viewInfo = <({int start, int length, int? stride})>[];
  for (final value in views) {
    final view = _map(value, 'bufferView');
    if (view['buffer'] != 0) fail('bufferView must use buffer 0');
    final start = _integer(view['byteOffset'] ?? 0, 'bufferView.byteOffset');
    final length = _integer(view['byteLength'], 'bufferView.byteLength');
    final stride = view['byteStride'] == null
        ? null
        : _integer(view['byteStride'], 'byteStride');
    if (start + length > bufferLength ||
        length == 0 ||
        (stride != null && (stride < 4 || stride > 252 || stride % 4 != 0))) {
      fail('invalid bufferView range or stride');
    }
    viewInfo.add((start: start, length: length, stride: stride));
  }
  final textures = _list(json['textures'], 'textures');
  if (allowEmbeddedBaseColorTextures) {
    final images = _list(json['images'], 'images');
    final samplers = _list(json['samplers'], 'samplers');
    if (images.length > VrzGlbTextureLimits.maxImages ||
        textures.length > VrzGlbTextureLimits.maxImages ||
        samplers.length > VrzGlbTextureLimits.maxImages) {
      fail('embedded texture count budget exceeded');
    }
    var decodedBytes = 0;
    final imagePixels = <int>[];
    for (final value in images) {
      final image = _map(value, 'image');
      if (image['mimeType'] != 'image/png') {
        fail('embedded images must declare image/png');
      }
      final view =
          viewInfo[_index(
            image['bufferView'],
            viewInfo.length,
            'image.bufferView',
          )];
      if (view.stride != null) fail('PNG bufferView cannot have byteStride');
      final size = VrlwBundleCodec.validatePngTextureBytes(
        Uint8List.sublistView(bin, view.start, view.start + view.length),
        requireComplete: true,
        maxDimension: VrzGlbTextureLimits.maxDimension,
      );
      if (size.width > VrzGlbTextureLimits.maxDimension ||
          size.height > VrzGlbTextureLimits.maxDimension) {
        fail('embedded PNG exceeds 256 pixels per side');
      }
      final pixels = size.width * size.height * 4;
      imagePixels.add(pixels);
      decodedBytes += pixels;
    }
    if (decodedBytes > VrzGlbTextureLimits.maxDecodedBytes) {
      fail('embedded PNG decoded-byte budget exceeded');
    }
    var uploadedBytes = 0;
    for (final value in textures) {
      final texture = _map(value, 'texture');
      final source = _index(texture['source'], images.length, 'texture.source');
      // The importer uploads once per texture entry, even for a shared image.
      uploadedBytes += imagePixels[source];
      if (texture.containsKey('sampler')) {
        _index(texture['sampler'], samplers.length, 'texture.sampler');
      }
    }
    if (uploadedBytes > VrzGlbTextureLimits.maxDecodedBytes) {
      fail('embedded texture upload budget exceeded');
    }
    for (final value in samplers) {
      final sampler = _map(value, 'sampler');
      bool validEnum(String key, List<int> allowed) =>
          !sampler.containsKey(key) ||
          (sampler[key] is int && allowed.contains(sampler[key]));
      if (!validEnum('magFilter', const [9728, 9729]) ||
          !validEnum('minFilter', const [9728, 9729, 9984, 9985, 9986, 9987]) ||
          !validEnum('wrapS', const [33071, 33648, 10497]) ||
          !validEnum('wrapT', const [33071, 33648, 10497])) {
        fail('unsupported embedded texture sampler');
      }
    }
  }
  final info =
      <
        ({
          int count,
          int component,
          String type,
          int maximum,
          double absoluteMaximum,
          bool normalized,
        })
      >[];
  var totalComponents = 0;
  final binaryData = ByteData.sublistView(bin);
  for (final value in accessors) {
    final accessor = _map(value, 'accessor');
    if (accessor.containsKey('sparse')) {
      fail('sparse accessors are unsupported');
    }
    final viewIndex = _index(
      accessor['bufferView'],
      viewInfo.length,
      'accessor.bufferView',
    );
    final view = viewInfo[viewIndex];
    final count = _integer(accessor['count'], 'accessor.count');
    final component = _integer(accessor['componentType'], 'componentType');
    final componentSize = switch (component) {
      5120 || 5121 => 1,
      5122 || 5123 => 2,
      5125 || 5126 => 4,
      _ => 0,
    };
    final type = accessor['type'];
    final components = switch (type) {
      'SCALAR' => 1,
      'VEC2' => 2,
      'VEC3' => 3,
      'VEC4' => 4,
      _ => 0,
    };
    final normalized = accessor['normalized'] ?? false;
    if (count == 0 ||
        count > 750000 ||
        componentSize == 0 ||
        components == 0 ||
        normalized is! bool ||
        (normalized && (component == 5125 || component == 5126))) {
      fail('unsupported accessor shape, component or count');
    }
    totalComponents += count * components;
    if (totalComponents > 4000000) fail('accessor component budget exceeded');
    final local = _integer(accessor['byteOffset'] ?? 0, 'accessor.byteOffset');
    final elementSize = componentSize * components;
    final stride = view.stride ?? elementSize;
    if (stride < elementSize ||
        stride % componentSize != 0 ||
        (view.start + local) % componentSize != 0 ||
        local + (count - 1) * stride + elementSize > view.length) {
      fail('accessor lies outside its bufferView');
    }
    var maximum = 0;
    var absoluteMaximum = 0.0;
    for (var item = 0; item < count; item++) {
      for (var channel = 0; channel < components; channel++) {
        final at = view.start + local + item * stride + channel * componentSize;
        if (component == 5126) {
          final number = binaryData.getFloat32(at, Endian.little);
          if (!number.isFinite || number.abs() > 1000000) {
            fail('non-finite or excessive geometry value');
          }
          if (number.abs() > absoluteMaximum) absoluteMaximum = number.abs();
        } else if (component == 5121 ||
            component == 5123 ||
            component == 5125) {
          final number = switch (component) {
            5121 => binaryData.getUint8(at),
            5123 => binaryData.getUint16(at, Endian.little),
            _ => binaryData.getUint32(at, Endian.little),
          };
          if (number > maximum) maximum = number;
        }
      }
    }
    info.add((
      count: count,
      component: component,
      type: type as String,
      maximum: maximum,
      absoluteMaximum: absoluteMaximum,
      normalized: normalized as bool,
    ));
  }
  final materials = _list(json['materials'], 'materials');
  if (materials.length > 256) fail('material budget exceeded');
  final texturedMaterials = <int>{};
  for (final value in materials) {
    final material = _map(value, 'material');
    if (material.containsKey('pbrMetallicRoughness')) {
      final pbr = _map(
        material['pbrMetallicRoughness'],
        'pbrMetallicRoughness',
      );
      if (pbr.containsKey('baseColorFactor')) {
        _unitVector(pbr['baseColorFactor'], 4);
      }
      for (final key in ['metallicFactor', 'roughnessFactor']) {
        if (pbr.containsKey(key)) _unitNumber(pbr[key]);
      }
      if (pbr.containsKey('baseColorTexture')) {
        final texture = _map(pbr['baseColorTexture'], 'baseColorTexture');
        _index(texture['index'], textures.length, 'baseColorTexture.index');
        if (_integer(texture['texCoord'] ?? 0, 'baseColorTexture.texCoord') !=
            0) {
          fail('embedded baseColorTexture must use TEXCOORD_0');
        }
        texturedMaterials.add(materials.indexOf(value));
      }
    }
    if (material.containsKey('emissiveFactor')) {
      _unitVector(material['emissiveFactor'], 3);
    }
    if (material.containsKey('alphaCutoff')) {
      _unitNumber(material['alphaCutoff']);
    }
    if ((material.containsKey('alphaMode') &&
            !['OPAQUE', 'MASK', 'BLEND'].contains(material['alphaMode'])) ||
        (material.containsKey('doubleSided') &&
            material['doubleSided'] is! bool)) {
      fail('invalid material alpha or culling setting');
    }
  }
  final meshes = _list(json['meshes'], 'meshes');
  if (meshes.isEmpty || meshes.length > 512) fail('mesh budget exceeded');
  final trianglesPerMesh = <int>[];
  final verticesPerMesh = <int>[];
  var primitiveCount = 0;
  for (final value in meshes) {
    final mesh = _map(value, 'mesh');
    if (mesh.containsKey('weights')) fail('morph weights are unsupported');
    final primitives = _list(mesh['primitives'], 'primitives');
    if (primitives.isEmpty) fail('mesh has no primitives');
    var triangles = 0;
    var vertices = 0;
    for (final value in primitives) {
      if (++primitiveCount > 2048) fail('primitive budget exceeded');
      final primitive = _map(value, 'primitive');
      if ((primitive['mode'] ?? 4) != 4 || primitive.containsKey('targets')) {
        fail('only triangle meshes without morph targets are supported');
      }
      final attributes = _map(primitive['attributes'], 'attributes');
      const allowed = {
        'POSITION',
        'NORMAL',
        'TANGENT',
        'TEXCOORD_0',
        'COLOR_0',
      };
      if (attributes.keys.any((key) => !allowed.contains(key))) {
        fail('unsupported vertex attribute');
      }
      final position =
          info[_index(attributes['POSITION'], info.length, 'POSITION')];
      if (position.type != 'VEC3' || position.component != 5126) {
        fail('POSITION must be float VEC3');
      }
      for (final entry in attributes.entries) {
        final attribute = info[_index(entry.value, info.length, 'attribute')];
        if (attribute.count != position.count) {
          fail('attribute vertex counts disagree');
        }
        final expected = switch (entry.key) {
          'POSITION' || 'NORMAL' => const ['VEC3'],
          'TANGENT' => const ['VEC4'],
          'TEXCOORD_0' => const ['VEC2'],
          _ => const ['VEC3', 'VEC4'],
        };
        if (!expected.contains(attribute.type)) {
          fail('invalid vertex attribute shape');
        }
        if ((entry.key == 'NORMAL' || entry.key == 'TANGENT') &&
            attribute.component != 5126) {
          fail('normals and tangents must use floats');
        }
        if (allowEmbeddedBaseColorTextures && entry.key == 'TEXCOORD_0') {
          if (!((attribute.component == 5126 && !attribute.normalized) ||
                  (const [5121, 5123].contains(attribute.component) &&
                      attribute.normalized)) ||
              attribute.absoluteMaximum > 4096) {
            fail(
              'TEXCOORD_0 must use bounded float or normalized unsigned UVs',
            );
          }
        }
      }
      var indexCount = position.count;
      if (primitive.containsKey('indices')) {
        final indices =
            info[_index(primitive['indices'], info.length, 'indices')];
        if (indices.type != 'SCALAR' ||
            ![5121, 5123, 5125].contains(indices.component) ||
            indices.normalized ||
            indices.maximum >= position.count) {
          fail('invalid triangle indices');
        }
        indexCount = indices.count;
      }
      if (indexCount % 3 != 0) {
        fail('triangle index count must be divisible by three');
      }
      if (primitive.containsKey('material')) {
        final material = _index(
          primitive['material'],
          materials.length,
          'material',
        );
        if (texturedMaterials.contains(material) &&
            !attributes.containsKey('TEXCOORD_0')) {
          fail('textured primitive requires TEXCOORD_0');
        }
      }
      triangles += indexCount ~/ 3;
      vertices += position.count;
    }
    trianglesPerMesh.add(triangles);
    verticesPerMesh.add(vertices);
  }
  final nodes = _list(json['nodes'], 'nodes');
  if (nodes.isEmpty || nodes.length > 2048) fail('node budget exceeded');
  final parents = <int>{};
  final children = <List<int>>[];
  final matrices = <vm.Matrix4>[];
  var submittedTriangles = 0;
  var submittedVertices = 0;
  for (final value in nodes) {
    final node = _map(value, 'node');
    if (node.containsKey('skin') ||
        node.containsKey('camera') ||
        node.containsKey('weights')) {
      fail('unsupported node feature');
    }
    if (node.containsKey('mesh')) {
      final mesh = _index(node['mesh'], meshes.length, 'node.mesh');
      submittedTriangles += trianglesPerMesh[mesh];
      submittedVertices += verticesPerMesh[mesh];
    }
    final nodeChildren = <int>[];
    for (final child in _list(node['children'], 'children')) {
      final index = _index(child, nodes.length, 'child');
      if (!parents.add(index)) fail('node has duplicate or multiple parents');
      nodeChildren.add(index);
    }
    children.add(nodeChildren);
    if (node.containsKey('matrix')) {
      if (['translation', 'rotation', 'scale'].any(node.containsKey)) {
        fail('matrix and TRS cannot coexist');
      }
      final matrix = _numbers(node['matrix'], 16, 10000);
      if (matrix[3] != 0 ||
          matrix[7] != 0 ||
          matrix[11] != 0 ||
          matrix[15] != 1) {
        fail('node matrix must be affine');
      }
      matrices.add(vm.Matrix4.fromList(matrix));
    } else {
      final t = _numbers(node['translation'] ?? [0, 0, 0], 3, 10000);
      final r = _numbers(node['rotation'] ?? [0, 0, 0, 1], 4, 1);
      final s = _numbers(node['scale'] ?? [1, 1, 1], 3, 100);
      if ((r.fold<double>(0, (sum, v) => sum + v * v) - 1).abs() > 0.001 ||
          s.any((v) => v.abs() < 0.0001)) {
        fail('invalid rotation or scale');
      }
      matrices.add(
        vm.Matrix4.compose(
          vm.Vector3(t[0], t[1], t[2]),
          vm.Quaternion(r[0], r[1], r[2], r[3]),
          vm.Vector3(s[0], s[1], s[2]),
        ),
      );
    }
  }
  if (submittedTriangles == 0 ||
      submittedTriangles > maxSubmittedTriangles ||
      submittedVertices > 250000) {
    fail('submitted geometry budget exceeded');
  }
  final visited = <int>{};
  void visit(int index, vm.Matrix4 parent, int depth) {
    if (depth > 32 || !visited.add(index)) {
      fail('cyclic or excessively deep node graph');
    }
    final world = vm.Matrix4.copy(parent)..multiply(matrices[index]);
    if (world.storage.any((n) => !n.isFinite || n.abs() > 1000000)) {
      fail('world transform exceeds its budget');
    }
    for (final child in children[index]) {
      visit(child, world, depth + 1);
    }
  }

  for (var i = 0; i < nodes.length; i++) {
    if (!parents.contains(i)) visit(i, vm.Matrix4.identity(), 0);
  }
  if (visited.length != nodes.length) fail('cyclic node graph');
  final scenes = _list(json['scenes'], 'scenes');
  if (scenes.isEmpty || scenes.length > 8) {
    fail('one to eight scenes are required');
  }
  _index(json['scene'] ?? 0, scenes.length, 'default scene');
  for (final value in scenes) {
    final roots = _list(_map(value, 'scene')['nodes'], 'scene.nodes');
    final seen = <int>{};
    for (final root in roots) {
      final index = _index(root, nodes.length, 'scene root');
      if (parents.contains(index) || !seen.add(index)) {
        fail('invalid scene root');
      }
    }
  }
}

/// Preflight nesting before jsonDecode, then validate every numeric leaf.
Map<String, Object?> decodeVrzJson(Uint8List bytes) {
  var depth = 0;
  var quoted = false;
  var escaped = false;
  for (final byte in bytes) {
    if (quoted) {
      if (escaped) {
        escaped = false;
      } else if (byte == 92) {
        escaped = true;
      } else if (byte == 34) {
        quoted = false;
      }
    } else if (byte == 34) {
      quoted = true;
    } else if (byte == 123 || byte == 91) {
      if (++depth > 64) throw const FormatException('JSON nesting exceeds 64.');
    } else if (byte == 125 || byte == 93) {
      depth--;
    }
  }
  final result = jsonDecode(utf8.decode(bytes));
  final root = _map(result, 'JSON root');
  _checkNumbers(root);
  return root;
}

void _checkNumbers(Object? value) {
  if (value is num && !value.isFinite) {
    throw const FormatException('Non-finite JSON number.');
  }
  if (value is Map) {
    for (final item in value.values) {
      _checkNumbers(item);
    }
  }
  if (value is List) {
    for (final item in value) {
      _checkNumbers(item);
    }
  }
}

void _checkTree(Object? value, {required bool allowEmbeddedBaseColorTextures}) {
  if (value is Map) {
    for (final entry in value.entries) {
      if (entry.key == 'name' && entry.value is! String) {
        throw const FormatException('GLB names must be strings.');
      }
      if (entry.key == 'uri' ||
          ((entry.key as String).endsWith('Texture') &&
              !(allowEmbeddedBaseColorTextures &&
                  entry.key == 'baseColorTexture'))) {
        throw const FormatException(
          'VRZ GLB must not reference external resources or textures.',
        );
      }
      if (entry.key == 'extensions') {
        final extensions = _map(entry.value, 'extensions');
        if (extensions.keys.any((key) => key != 'KHR_materials_unlit') ||
            extensions.values.any((item) => item is! Map || item.isNotEmpty)) {
          throw const FormatException('Unsupported GLB extension.');
        }
      }
      _checkTree(
        entry.value,
        allowEmbeddedBaseColorTextures: allowEmbeddedBaseColorTextures,
      );
    }
  } else if (value is List) {
    for (final item in value) {
      _checkTree(
        item,
        allowEmbeddedBaseColorTextures: allowEmbeddedBaseColorTextures,
      );
    }
  }
}

void _unitNumber(Object? value) {
  if (value is! num || !value.isFinite || value < 0 || value > 1) {
    throw const FormatException('Material factors must be within [0, 1].');
  }
}

void _unitVector(Object? value, int length) {
  if (value is! List || value.length != length) {
    throw const FormatException('Invalid material factor vector.');
  }
  for (final item in value) {
    _unitNumber(item);
  }
}

Map<String, Object?> _map(Object? value, String name) {
  if (value is! Map<String, dynamic>) {
    throw FormatException('$name must be an object.');
  }
  return value;
}

List<dynamic> _list(Object? value, String name) {
  if (value == null) return const [];
  if (value is! List) throw FormatException('$name must be an array.');
  return value;
}

int _integer(Object? value, String name) {
  if (value is! int || value < 0) {
    throw FormatException('$name must be a nonnegative integer.');
  }
  return value;
}

int _index(Object? value, int length, String name) {
  final index = _integer(value, name);
  if (index >= length) throw FormatException('$name index is out of range.');
  return index;
}

List<double> _numbers(Object? value, int length, double bound) {
  if (value is! List ||
      value.length != length ||
      value.any((v) => v is! num || !v.isFinite || v.abs() > bound)) {
    throw const FormatException('Invalid or excessive transform values.');
  }
  return value.map((v) => (v as num).toDouble()).toList();
}
