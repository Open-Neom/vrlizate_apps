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

/// Admission limits for the extended v1 PBR/KTX2/meshopt/animation GLB profile.
abstract final class VrzGlbExtendedLimits {
  static const maxImages = 32;
  static const maxDimension = 2048;
  static const maxEstimatedVramBytes = 16 * 1024 * 1024;
  static const maxMeshoptDecodedBytes = 16 * 1024 * 1024;
  static const maxSkins = 64;
  static const maxAnimations = 64;
  static const maxMorphTargets = 8;

  static const Set<String> allowedExtensions = {
    'KHR_materials_unlit',
    'KHR_texture_basisu',
    'EXT_meshopt_compression',
    'KHR_texture_transform',
    'KHR_lights_punctual',
    'KHR_materials_emissive_strength',
    'KHR_materials_clearcoat',
    'KHR_materials_sheen',
    'KHR_materials_transmission',
    'KHR_materials_ior',
    'KHR_materials_specular',
    'KHR_materials_iridescence',
    'KHR_materials_anisotropy',
    'KHR_materials_volume',
    'KHR_materials_dispersion',
    'KHR_materials_diffuse_transmission',
    'KHR_materials_variants',
    'KHR_mesh_quantization',
  };
}

/// Deterministic geometry and GPU-memory stats extracted during GLB validation.
typedef VrzGlbStats = ({
  int submittedTriangles,
  int submittedVertices,
  int estimatedVramBytes,
});

const List<int> _ktx2Magic = <int>[
  0xAB,
  0x4B,
  0x54,
  0x58,
  0x20,
  0x32,
  0x30,
  0xBB,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
];

/// The scene subset is intentionally smaller than all of glTF 2.0.
/// Base `vrlizate.scene.v1` scenes remain texture-free; base `vrlizate.worlds.v1`
/// places opt into bounded base-color PNGs, and extended `v1` capabilities opt into
/// PBR, KTX2 BasisU, meshopt compression, lightmap UVs (`TEXCOORD_1`), skinning,
/// and animations.
void validateVrzGlb(
  Uint8List bytes, {
  int maxSubmittedTriangles = 250000,
  bool allowEmbeddedBaseColorTextures = false,
  bool allowExtendedGraphics = false,
}) {
  inspectVrzGlbStats(
    bytes,
    maxSubmittedTriangles: maxSubmittedTriangles,
    allowEmbeddedBaseColorTextures: allowEmbeddedBaseColorTextures,
    allowExtendedGraphics: allowExtendedGraphics,
  );
}

/// Validates [bytes] and returns deterministic geometry and VRAM accounting.
VrzGlbStats inspectVrzGlbStats(
  Uint8List bytes, {
  int maxSubmittedTriangles = 250000,
  bool allowEmbeddedBaseColorTextures = false,
  bool allowExtendedGraphics = false,
}) {
  Never fail(String message) => throw FormatException('VRZ GLB: $message');
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
  final json = root;
  final bin = binary;
  final asset = _map(json['asset'], 'asset');
  if (asset['version'] != '2.0' ||
      (asset['minVersion'] != null && asset['minVersion'] != '2.0')) {
    fail('unsupported glTF asset version');
  }
  final allowTextures = allowEmbeddedBaseColorTextures || allowExtendedGraphics;
  _checkTree(
    json,
    allowEmbeddedBaseColorTextures: allowEmbeddedBaseColorTextures,
    allowExtendedGraphics: allowExtendedGraphics,
  );
  for (final key in [
    if (!allowTextures) ...['images', 'textures', 'samplers'],
    if (!allowExtendedGraphics) ...['animations', 'skins'],
    'cameras',
  ]) {
    if (_list(json[key], key).isNotEmpty) {
      fail('$key are not supported in version 1');
    }
  }
  final allowedExtensions = allowExtendedGraphics
      ? VrzGlbExtendedLimits.allowedExtensions
      : const {'KHR_materials_unlit'};
  for (final key in ['extensionsUsed', 'extensionsRequired']) {
    final extensions = _list(json[key], key);
    if (extensions.toSet().length != extensions.length ||
        extensions.any(
          (value) => value is! String || !allowedExtensions.contains(value),
        )) {
      fail('unsupported or duplicate extensions');
    }
  }
  final buffers = _list(json['buffers'], 'buffers');
  if (buffers.isEmpty ||
      (!allowExtendedGraphics && buffers.length != 1) ||
      buffers.length > 8) {
    fail('exactly one embedded buffer is required');
  }
  final primaryBuffer = _map(buffers.first, 'buffer');
  final bufferLength = _integer(
    primaryBuffer['byteLength'],
    'buffer.byteLength',
  );
  if (bufferLength > bin.length || bin.length - bufferLength > 3) {
    fail('buffer length disagrees with BIN');
  }
  final fallbackBuffers = <int>{};
  for (var i = 1; i < buffers.length; i++) {
    final extra = _map(buffers[i], 'buffer');
    _integer(extra['byteLength'], 'buffer.byteLength');
    final ext = extra['extensions'];
    final meshopt = ext is Map ? ext['EXT_meshopt_compression'] : null;
    if (meshopt is! Map || meshopt['fallback'] != true) {
      fail('secondary buffers must be EXT_meshopt_compression fallbacks');
    }
    fallbackBuffers.add(i);
  }
  final views = _list(json['bufferViews'], 'bufferViews');
  final accessors = _list(json['accessors'], 'accessors');
  if (views.length > 4096 || accessors.length > 4096) {
    fail('too many buffer views or accessors');
  }
  var totalMeshoptDecoded = 0;
  final viewInfo = <({int start, int length, int? stride, bool isMeshopt})>[];
  for (final value in views) {
    final view = _map(value, 'bufferView');
    final ext = view['extensions'];
    final meshopt = allowExtendedGraphics && ext is Map
        ? ext['EXT_meshopt_compression']
        : null;
    final stride = view['byteStride'] == null
        ? null
        : _integer(view['byteStride'], 'byteStride');
    if (stride != null && (stride < 4 || stride > 252 || stride % 4 != 0)) {
      fail('invalid bufferView range or stride');
    }
    if (meshopt != null) {
      final comp = _map(meshopt, 'EXT_meshopt_compression');
      if (comp['buffer'] != 0) {
        fail('EXT_meshopt_compression must read from buffer 0');
      }
      final viewBuf = _integer(view['buffer'], 'bufferView.buffer');
      if (viewBuf != 0 && !fallbackBuffers.contains(viewBuf)) {
        fail('meshopt bufferView must reference buffer 0 or fallback buffer');
      }
      final compOffset = _integer(
        comp['byteOffset'] ?? 0,
        'meshopt.byteOffset',
      );
      final compLength = _integer(comp['byteLength'], 'meshopt.byteLength');
      final compStride = _integer(comp['byteStride'], 'meshopt.byteStride');
      final compCount = _integer(comp['count'], 'meshopt.count');
      final declaredLength = _integer(view['byteLength'], 'view.byteLength');
      if (compLength == 0 ||
          compOffset + compLength > bufferLength ||
          compStride < 1 ||
          compStride > 256 ||
          compCount == 0 ||
          compCount * compStride != declaredLength) {
        fail('invalid EXT_meshopt_compression range');
      }
      totalMeshoptDecoded += declaredLength;
      if (totalMeshoptDecoded > VrzGlbExtendedLimits.maxMeshoptDecodedBytes) {
        fail('meshopt decoded byte budget exceeded');
      }
      viewInfo.add((
        start: 0,
        length: declaredLength,
        stride: stride,
        isMeshopt: true,
      ));
      continue;
    }
    if (view['buffer'] != 0) fail('bufferView must use buffer 0');
    final start = _integer(view['byteOffset'] ?? 0, 'bufferView.byteOffset');
    final length = _integer(view['byteLength'], 'bufferView.byteLength');
    if (start + length > bufferLength || length == 0) {
      fail('invalid bufferView range or stride');
    }
    viewInfo.add((
      start: start,
      length: length,
      stride: stride,
      isMeshopt: false,
    ));
  }

  final textures = _list(json['textures'], 'textures');
  var uploadedVramBytes = 0;
  if (allowTextures) {
    final images = _list(json['images'], 'images');
    final samplers = _list(json['samplers'], 'samplers');
    final maxImages = allowExtendedGraphics
        ? VrzGlbExtendedLimits.maxImages
        : VrzGlbTextureLimits.maxImages;
    final maxDim = allowExtendedGraphics
        ? VrzGlbExtendedLimits.maxDimension
        : VrzGlbTextureLimits.maxDimension;
    final maxVram = allowExtendedGraphics
        ? VrzGlbExtendedLimits.maxEstimatedVramBytes
        : VrzGlbTextureLimits.maxDecodedBytes;
    if (images.length > maxImages ||
        textures.length > maxImages ||
        samplers.length > maxImages) {
      fail('embedded texture count budget exceeded');
    }
    var decodedBytes = 0;
    final imageVramBytes = <int>[];
    for (final value in images) {
      final image = _map(value, 'image');
      final mime = image['mimeType'];
      final viewIdx = _index(
        image['bufferView'],
        viewInfo.length,
        'image.bufferView',
      );
      final view = viewInfo[viewIdx];
      if (view.stride != null || view.isMeshopt) {
        fail('image bufferView cannot have byteStride or meshopt');
      }
      final imgBytes = Uint8List.sublistView(
        bin,
        view.start,
        view.start + view.length,
      );
      int estimatedBytes;
      if (mime == 'image/png') {
        final size = VrlwBundleCodec.validatePngTextureBytes(
          imgBytes,
          requireComplete: true,
          maxDimension: maxDim,
        );
        if (size.width > maxDim || size.height > maxDim) {
          fail('embedded PNG exceeds dimension budget');
        }
        estimatedBytes = size.width * size.height * 4;
      } else if (allowExtendedGraphics && mime == 'image/ktx2') {
        final size = _validateKtx2Bytes(imgBytes, maxDim);
        // Transcoded GPU block formats (ASTC/ETC2/BC7) + mip chain average
        // <= 10.67 bits/pixel (~1/3 of uncompressed RGBA8).
        estimatedBytes = (size.width * size.height * 4 + 2) ~/ 3;
      } else if (allowExtendedGraphics && mime == 'image/jpeg') {
        final size = _validateJpegBytes(imgBytes, maxDim);
        estimatedBytes = size.width * size.height * 4;
      } else {
        fail(
          allowExtendedGraphics
              ? 'embedded images must declare image/png, image/jpeg or image/ktx2'
              : 'embedded images must declare image/png',
        );
      }
      imageVramBytes.add(estimatedBytes);
      decodedBytes += estimatedBytes;
    }
    if (decodedBytes > maxVram) {
      fail('embedded texture decoded-byte budget exceeded');
    }
    for (final value in textures) {
      final texture = _map(value, 'texture');
      int? sourceIndex;
      if (allowExtendedGraphics && texture['extensions'] is Map) {
        final texExt = _map(texture['extensions'], 'texture.extensions');
        if (texExt.containsKey('KHR_texture_basisu')) {
          final basisu = _map(
            texExt['KHR_texture_basisu'],
            'KHR_texture_basisu',
          );
          sourceIndex = _index(
            basisu['source'],
            images.length,
            'KHR_texture_basisu.source',
          );
        }
      }
      if (texture.containsKey('source')) {
        final fallbackSource = _index(
          texture['source'],
          images.length,
          'texture.source',
        );
        sourceIndex ??= fallbackSource;
      }
      if (sourceIndex == null) {
        fail('texture requires source or KHR_texture_basisu.source');
      }
      uploadedVramBytes += imageVramBytes[sourceIndex];
      if (texture.containsKey('sampler')) {
        _index(texture['sampler'], samplers.length, 'texture.sampler');
      }
    }
    if (uploadedVramBytes > maxVram) {
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
          bool isMeshopt,
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
      'MAT4' when allowExtendedGraphics => 16,
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
    if (totalComponents > (allowExtendedGraphics ? 8000000 : 4000000)) {
      fail('accessor component budget exceeded');
    }
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
    if (!view.isMeshopt) {
      for (var item = 0; item < count; item++) {
        for (var channel = 0; channel < components; channel++) {
          final at =
              view.start + local + item * stride + channel * componentSize;
          if (component == 5126) {
            final number = binaryData.getFloat32(at, Endian.little);
            if (!number.isFinite || number.abs() > 1000000) {
              fail('non-finite or excessive geometry value');
            }
            if (number.abs() > absoluteMaximum) {
              absoluteMaximum = number.abs();
            }
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
    }
    info.add((
      count: count,
      component: component,
      type: type as String,
      maximum: maximum,
      absoluteMaximum: absoluteMaximum,
      normalized: normalized,
      isMeshopt: view.isMeshopt,
    ));
  }

  final materials = _list(json['materials'], 'materials');
  if (materials.length > 256) fail('material budget exceeded');
  final materialsNeedingUv0 = <int>{};
  final materialsNeedingUv1 = <int>{};
  void checkTextureInfo(
    Object? rawInfo,
    String label,
    int matIdx, {
    bool allowScale = false,
    bool allowStrength = false,
  }) {
    final texInfo = _map(rawInfo, label);
    _index(texInfo['index'], textures.length, '$label.index');
    final uv = _integer(texInfo['texCoord'] ?? 0, '$label.texCoord');
    if (!allowExtendedGraphics && uv != 0) {
      fail('embedded $label must use TEXCOORD_0');
    }
    if (uv != 0 && uv != 1) {
      fail('$label texCoord must be 0 or 1');
    }
    if (uv == 0) {
      materialsNeedingUv0.add(matIdx);
    } else {
      materialsNeedingUv1.add(matIdx);
    }
    if (allowScale && texInfo.containsKey('scale')) {
      final scale = texInfo['scale'];
      if (scale is! num || !scale.isFinite || scale < 0 || scale > 64) {
        fail('invalid normalTexture scale');
      }
    }
    if (allowStrength && texInfo.containsKey('strength')) {
      _unitNumber(texInfo['strength']);
    }
  }

  for (var matIdx = 0; matIdx < materials.length; matIdx++) {
    final material = _map(materials[matIdx], 'material');
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
        checkTextureInfo(pbr['baseColorTexture'], 'baseColorTexture', matIdx);
      }
      if (allowExtendedGraphics && pbr.containsKey('metallicRoughnessTexture')) {
        checkTextureInfo(
          pbr['metallicRoughnessTexture'],
          'metallicRoughnessTexture',
          matIdx,
        );
      }
    }
    if (allowExtendedGraphics) {
      if (material.containsKey('normalTexture')) {
        checkTextureInfo(
          material['normalTexture'],
          'normalTexture',
          matIdx,
          allowScale: true,
        );
      }
      if (material.containsKey('occlusionTexture')) {
        checkTextureInfo(
          material['occlusionTexture'],
          'occlusionTexture',
          matIdx,
          allowStrength: true,
        );
      }
      if (material.containsKey('emissiveTexture')) {
        checkTextureInfo(material['emissiveTexture'], 'emissiveTexture', matIdx);
      }
      if (material['extensions'] is Map) {
        final ext = _map(material['extensions'], 'material.extensions');
        if (ext.containsKey('KHR_materials_emissive_strength')) {
          final es = _map(
            ext['KHR_materials_emissive_strength'],
            'KHR_materials_emissive_strength',
          );
          if (es.containsKey('emissiveStrength')) {
            final s = es['emissiveStrength'];
            if (s is! num || !s.isFinite || s < 0 || s > 1000) {
              fail('invalid emissiveStrength');
            }
          }
        }
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
    if (mesh.containsKey('weights')) {
      if (!allowExtendedGraphics) fail('morph weights are unsupported');
      final weights = _list(mesh['weights'], 'mesh.weights');
      if (weights.isEmpty || weights.length > VrzGlbExtendedLimits.maxMorphTargets) {
        fail('morph weights budget exceeded');
      }
      _numbers(weights, weights.length, 100);
    }
    final primitives = _list(mesh['primitives'], 'primitives');
    if (primitives.isEmpty) fail('mesh has no primitives');
    var triangles = 0;
    var vertices = 0;
    for (final value in primitives) {
      if (++primitiveCount > 2048) fail('primitive budget exceeded');
      final primitive = _map(value, 'primitive');
      if ((primitive['mode'] ?? 4) != 4 ||
          (!allowExtendedGraphics && primitive.containsKey('targets'))) {
        fail('only triangle meshes without morph targets are supported');
      }
      final attributes = _map(primitive['attributes'], 'attributes');
      final allowed = allowExtendedGraphics
          ? const {
              'POSITION',
              'NORMAL',
              'TANGENT',
              'TEXCOORD_0',
              'TEXCOORD_1',
              'COLOR_0',
              'JOINTS_0',
              'WEIGHTS_0',
            }
          : const {'POSITION', 'NORMAL', 'TANGENT', 'TEXCOORD_0', 'COLOR_0'};
      if (attributes.keys.any((key) => !allowed.contains(key))) {
        fail('unsupported vertex attribute');
      }
      final position =
          info[_index(attributes['POSITION'], info.length, 'POSITION')];
      if (position.type != 'VEC3' ||
          (!allowExtendedGraphics && position.component != 5126) ||
          (allowExtendedGraphics &&
              !const [5120, 5121, 5122, 5123, 5126].contains(
                position.component,
              ))) {
        fail('POSITION must be float VEC3');
      }
      if (allowExtendedGraphics && primitive.containsKey('targets')) {
        final targets = _list(primitive['targets'], 'primitive.targets');
        if (targets.isEmpty || targets.length > VrzGlbExtendedLimits.maxMorphTargets) {
          fail('morph target budget exceeded');
        }
        for (final rawTarget in targets) {
          final target = _map(rawTarget, 'morphTarget');
          for (final entry in target.entries) {
            if (!const {'POSITION', 'NORMAL', 'TANGENT'}.contains(entry.key)) {
              fail('unsupported morph target attribute');
            }
            final acc = info[_index(entry.value, info.length, entry.key)];
            if (acc.count != position.count || acc.type != 'VEC3') {
              fail('invalid morph target accessor');
            }
          }
        }
      }
      for (final entry in attributes.entries) {
        final attribute = info[_index(entry.value, info.length, 'attribute')];
        if (attribute.count != position.count) {
          fail('attribute vertex counts disagree');
        }
        final expected = switch (entry.key) {
          'POSITION' || 'NORMAL' => const ['VEC3'],
          'TANGENT' || 'JOINTS_0' || 'WEIGHTS_0' => const ['VEC4'],
          'TEXCOORD_0' || 'TEXCOORD_1' => const ['VEC2'],
          _ => const ['VEC3', 'VEC4'],
        };
        if (!expected.contains(attribute.type)) {
          fail('invalid vertex attribute shape');
        }
        if (!allowExtendedGraphics &&
            (entry.key == 'NORMAL' || entry.key == 'TANGENT') &&
            attribute.component != 5126) {
          fail('normals and tangents must use floats');
        }
        if (entry.key == 'JOINTS_0' &&
            (!const [5121, 5123].contains(attribute.component) ||
                attribute.normalized)) {
          fail('JOINTS_0 must use non-normalized unsigned byte or short');
        }
        if (entry.key == 'WEIGHTS_0' &&
            !((attribute.component == 5126 && !attribute.normalized) ||
                (const [5121, 5123].contains(attribute.component) &&
                    attribute.normalized))) {
          fail('WEIGHTS_0 must use float or normalized unsigned integers');
        }
        if (allowTextures &&
            (entry.key == 'TEXCOORD_0' || entry.key == 'TEXCOORD_1')) {
          if (!((attribute.component == 5126 && !attribute.normalized) ||
                  (const [5121, 5123].contains(attribute.component) &&
                      attribute.normalized)) ||
              (!attribute.isMeshopt && attribute.absoluteMaximum > 4096)) {
            fail(
              '${entry.key} must use bounded float or normalized unsigned UVs',
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
            (!indices.isMeshopt && indices.maximum >= position.count)) {
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
        if (materialsNeedingUv0.contains(material) &&
            !attributes.containsKey('TEXCOORD_0')) {
          fail('textured primitive requires TEXCOORD_0');
        }
        if (materialsNeedingUv1.contains(material) &&
            !attributes.containsKey('TEXCOORD_1')) {
          fail('textured primitive requires TEXCOORD_1');
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
  final skins = _list(json['skins'], 'skins');
  if (allowExtendedGraphics && skins.length > VrzGlbExtendedLimits.maxSkins) {
    fail('skin budget exceeded');
  }
  for (final value in skins) {
    final skin = _map(value, 'skin');
    final joints = _list(skin['joints'], 'skin.joints');
    if (joints.isEmpty || joints.length > 256) fail('invalid skin joints');
    for (final joint in joints) {
      _index(joint, nodes.length, 'skin.joint');
    }
    if (skin.containsKey('skeleton')) {
      _index(skin['skeleton'], nodes.length, 'skin.skeleton');
    }
    if (skin.containsKey('inverseBindMatrices')) {
      final ibm = info[
        _index(
          skin['inverseBindMatrices'],
          info.length,
          'skin.inverseBindMatrices',
        )
      ];
      if (ibm.type != 'MAT4' ||
          ibm.component != 5126 ||
          ibm.count != joints.length) {
        fail('invalid inverseBindMatrices accessor');
      }
    }
  }

  final animations = _list(json['animations'], 'animations');
  if (allowExtendedGraphics && animations.length > VrzGlbExtendedLimits.maxAnimations) {
    fail('animation budget exceeded');
  }
  for (final value in animations) {
    final anim = _map(value, 'animation');
    final samplers = _list(anim['samplers'], 'animation.samplers');
    final channels = _list(anim['channels'], 'animation.channels');
    if (samplers.isEmpty ||
        samplers.length > 512 ||
        channels.isEmpty ||
        channels.length > 512) {
      fail('invalid animation samplers or channels');
    }
    for (final rawSampler in samplers) {
      final sampler = _map(rawSampler, 'animation.sampler');
      final input = info[_index(sampler['input'], info.length, 'sampler.input')];
      _index(sampler['output'], info.length, 'sampler.output');
      if (input.type != 'SCALAR' || input.component != 5126) {
        fail('animation input must be float SCALAR');
      }
    }
    for (final rawChannel in channels) {
      final channel = _map(rawChannel, 'animation.channel');
      _index(channel['sampler'], samplers.length, 'channel.sampler');
      final target = _map(channel['target'], 'channel.target');
      if (target.containsKey('node')) {
        _index(target['node'], nodes.length, 'channel.target.node');
      }
      if (!const {
        'translation',
        'rotation',
        'scale',
        'weights',
      }.contains(target['path'])) {
        fail('unsupported animation target path');
      }
    }
  }

  final parents = <int>{};
  final children = <List<int>>[];
  final matrices = <vm.Matrix4>[];
  var submittedTriangles = 0;
  var submittedVertices = 0;
  for (final value in nodes) {
    final node = _map(value, 'node');
    if (node.containsKey('camera') ||
        (!allowExtendedGraphics &&
            (node.containsKey('skin') || node.containsKey('weights')))) {
      fail('unsupported node feature');
    }
    if (allowExtendedGraphics && node.containsKey('skin')) {
      _index(node['skin'], skins.length, 'node.skin');
    }
    if (allowExtendedGraphics && node.containsKey('weights')) {
      final w = _list(node['weights'], 'node.weights');
      if (w.isEmpty || w.length > VrzGlbExtendedLimits.maxMorphTargets) {
        fail('node weights budget exceeded');
      }
      _numbers(w, w.length, 100);
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
      submittedVertices > (allowExtendedGraphics ? 500000 : 250000)) {
    fail('submitted geometry budget exceeded');
  }
  final visited = <int>{};
  void visit(int index, vm.Matrix4 parent, int depth) {
    if (depth > (allowExtendedGraphics ? 64 : 32) || !visited.add(index)) {
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
  return (
    submittedTriangles: submittedTriangles,
    submittedVertices: submittedVertices,
    estimatedVramBytes: uploadedVramBytes,
  );
}

({int width, int height}) _validateKtx2Bytes(Uint8List bytes, int maxDim) {
  if (bytes.length < 80) {
    throw const FormatException('VRZ GLB: truncated KTX2 image.');
  }
  for (var i = 0; i < _ktx2Magic.length; i++) {
    if (bytes[i] != _ktx2Magic[i]) {
      throw const FormatException('VRZ GLB: invalid KTX2 magic.');
    }
  }
  final view = ByteData.sublistView(bytes);
  final width = view.getUint32(20, Endian.little);
  final height = view.getUint32(24, Endian.little);
  final depth = view.getUint32(28, Endian.little);
  final faces = view.getUint32(36, Endian.little);
  if (width < 1 ||
      width > maxDim ||
      height < 1 ||
      height > maxDim ||
      depth > 1 ||
      faces != 1) {
    throw const FormatException(
      'VRZ GLB: KTX2 dimensions exceed 2D texture budget.',
    );
  }
  return (width: width, height: height);
}

({int width, int height}) _validateJpegBytes(Uint8List bytes, int maxDim) {
  if (bytes.length < 24 ||
      bytes[0] != 0xFF ||
      bytes[1] != 0xD8 ||
      bytes[bytes.length - 2] != 0xFF ||
      bytes[bytes.length - 1] != 0xD9) {
    throw const FormatException('VRZ GLB: invalid JPEG envelope.');
  }
  var offset = 2;
  while (offset + 4 <= bytes.length) {
    if (bytes[offset] != 0xFF) {
      offset++;
      continue;
    }
    while (offset < bytes.length && bytes[offset] == 0xFF) {
      offset++;
    }
    if (offset >= bytes.length) break;
    final marker = bytes[offset++];
    if (marker == 0xD9 || marker == 0xDA) break;
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) continue;
    if (offset + 2 > bytes.length) break;
    final segLen = (bytes[offset] << 8) | bytes[offset + 1];
    if (segLen < 2 || offset + segLen > bytes.length) {
      throw const FormatException('VRZ GLB: truncated JPEG segment.');
    }
    if (marker == 0xC0 || marker == 0xC1 || marker == 0xC2) {
      if (segLen < 7) {
        throw const FormatException('VRZ GLB: invalid JPEG SOF header.');
      }
      final height = (bytes[offset + 3] << 8) | bytes[offset + 4];
      final width = (bytes[offset + 5] << 8) | bytes[offset + 6];
      if (width < 1 || width > maxDim || height < 1 || height > maxDim) {
        throw const FormatException(
          'VRZ GLB: JPEG dimensions exceed texture budget.',
        );
      }
      return (width: width, height: height);
    }
    offset += segLen;
  }
  throw const FormatException('VRZ GLB: JPEG missing baseline/progressive SOF.');
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

void _checkTree(
  Object? value, {
  required bool allowEmbeddedBaseColorTextures,
  required bool allowExtendedGraphics,
}) {
  if (value is Map) {
    for (final entry in value.entries) {
      if (entry.key == 'name' && entry.value is! String) {
        throw const FormatException('GLB names must be strings.');
      }
      final key = entry.key as String;
      if (key == 'uri') {
        throw const FormatException(
          'VRZ GLB must not reference external resources or textures.',
        );
      }
      if (!allowExtendedGraphics &&
          key.endsWith('Texture') &&
          !(allowEmbeddedBaseColorTextures && key == 'baseColorTexture')) {
        throw const FormatException(
          'VRZ GLB must not reference external resources or textures.',
        );
      }
      if (key == 'extensions') {
        final extensions = _map(entry.value, 'extensions');
        if (!allowExtendedGraphics) {
          if (extensions.keys.any((ext) => ext != 'KHR_materials_unlit') ||
              extensions.values.any((item) => item is! Map || item.isNotEmpty)) {
            throw const FormatException('Unsupported GLB extension.');
          }
        } else {
          if (extensions.keys.any(
                (ext) => !VrzGlbExtendedLimits.allowedExtensions.contains(ext),
              ) ||
              extensions.values.any((item) => item is! Map)) {
            throw const FormatException('Unsupported GLB extension.');
          }
        }
      }
      _checkTree(
        entry.value,
        allowEmbeddedBaseColorTextures: allowEmbeddedBaseColorTextures,
        allowExtendedGraphics: allowExtendedGraphics,
      );
    }
  } else if (value is List) {
    for (final item in value) {
      _checkTree(
        item,
        allowEmbeddedBaseColorTextures: allowEmbeddedBaseColorTextures,
        allowExtendedGraphics: allowExtendedGraphics,
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
