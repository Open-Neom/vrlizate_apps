/// Immutable metadata for the deliberately small VRZ scene runtime.
final class VrzManifest {
  VrzManifest._({
    required this.formatVersion,
    required this.runtime,
    required List<String> capabilities,
    required this.id,
    required this.title,
    required this.description,
    required this.sceneSha256,
    required List<double> position,
    required List<double> target,
    Map<String, Object?> extensions = const {},
  }) : capabilities = List.unmodifiable(capabilities),
       cameraPosition = List.unmodifiable(position),
       cameraTarget = List.unmodifiable(target),
       extensions = Map.unmodifiable(extensions);

  static const supportedRuntime = 'vrlizate.scene.v1';
  static const supportedRuntimeV2 = 'vrlizate.scene.v2';
  static const supportedCapability = 'scene.gltf2';
  static const Set<String> supportedCapabilitiesV2 = {
    'scene.gltf2',
    'scene.pbr',
    'scene.ktx2',
    'scene.meshopt',
    'scene.animation',
    'scene.lightmap',
  };

  final int formatVersion;
  final String runtime;
  final List<String> capabilities;
  final String id;
  final String title;
  final String description;
  final String sceneSha256;
  final List<double> cameraPosition;
  final List<double> cameraTarget;
  final Map<String, Object?> extensions;

  bool get isV2 => formatVersion == 2 && runtime == supportedRuntimeV2;
  String get entrypoint => 'scene.glb';
  String get entrypointName => entrypoint;

  factory VrzManifest.fromJson(Map<String, Object?> json) {
    final version = json['formatVersion'];
    final runtime = json['runtime'];
    final isV1 = version == 1 && runtime == supportedRuntime;
    final isV2 = version == 2 && runtime == supportedRuntimeV2;
    if (version is! int || (!isV1 && !isV2) || json['entrypoint'] != 'scene.glb') {
      throw const FormatException(
        'Unsupported VRZ version, runtime or entrypoint.',
      );
    }
    final allowedFields = isV2
        ? const {
            'formatVersion',
            'id',
            'title',
            'description',
            'runtime',
            'entrypoint',
            'capabilities',
            'sha256',
            'camera',
            'extensions',
          }
        : const {
            'formatVersion',
            'id',
            'title',
            'description',
            'runtime',
            'entrypoint',
            'capabilities',
            'sha256',
            'camera',
          };
    if (json.keys.any((key) => !allowedFields.contains(key))) {
      throw const FormatException('Unknown VRZ manifest field.');
    }
    final rawCapabilities = json['capabilities'];
    if (rawCapabilities is! List || rawCapabilities.isEmpty) {
      throw const FormatException('Unsupported VRZ capabilities.');
    }
    final parsedCapabilities = <String>[];
    if (isV1) {
      if (rawCapabilities.length != 1 ||
          rawCapabilities.single != supportedCapability) {
        throw const FormatException('Unsupported VRZ capabilities.');
      }
      parsedCapabilities.add(supportedCapability);
    } else {
      final seen = <String>{};
      for (final cap in rawCapabilities) {
        if (cap is! String ||
            !supportedCapabilitiesV2.contains(cap) ||
            !seen.add(cap)) {
          throw const FormatException('Unsupported VRZ capabilities.');
        }
        parsedCapabilities.add(cap);
      }
      if (!seen.contains(supportedCapability)) {
        throw const FormatException('VRZ v2 requires scene.gltf2 capability.');
      }
    }
    var extensions = const <String, Object?>{};
    if (isV2 && json.containsKey('extensions')) {
      final rawExt = json['extensions'];
      if (rawExt is! Map<String, Object?> || rawExt.length > 16) {
        throw const FormatException('Invalid VRZ extensions map.');
      }
      extensions = Map<String, Object?>.from(rawExt);
    }
    final id = json['id'];
    if (id is! String ||
        id.length > 128 ||
        !RegExp(r'^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)+$').hasMatch(id)) {
      throw const FormatException(
        'VRZ id must be a lowercase namespaced identifier.',
      );
    }
    final title = json['title'];
    final description = json['description'] ?? '';
    if (title is! String ||
        title.trim().isEmpty ||
        title.length > 80 ||
        description is! String ||
        description.length > 512) {
      throw const FormatException('Invalid VRZ title or description.');
    }
    final hashes = json['sha256'];
    if (hashes is! Map ||
        hashes.length != 1 ||
        hashes['scene.glb'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(hashes['scene.glb'] as String)) {
      throw const FormatException(
        'A lowercase SHA-256 for scene.glb is required.',
      );
    }
    var position = <double>[0, 1.6, 6];
    var target = <double>[0, 1, -6];
    if (json.containsKey('camera')) {
      final camera = json['camera'];
      if (camera is! Map ||
          camera.length != 2 ||
          !camera.containsKey('position') ||
          !camera.containsKey('target')) {
        throw const FormatException('Camera requires position and target.');
      }
      position = _vector(camera['position']);
      target = _vector(camera['target']);
    }
    final dx = target[0] - position[0];
    final dz = target[2] - position[2];
    // Both renderers use +Y as up, so a vertical direction is degenerate too.
    if (dx * dx + dz * dz < 1e-12) {
      throw const FormatException(
        'Camera direction must be distinct and nonvertical.',
      );
    }
    return VrzManifest._(
      formatVersion: version,
      runtime: runtime as String,
      capabilities: parsedCapabilities,
      id: id,
      title: title,
      description: description,
      sceneSha256: hashes['scene.glb'] as String,
      position: position,
      target: target,
      extensions: extensions,
    );
  }

  Map<String, Object?> toJson() => {
    'formatVersion': formatVersion,
    'id': id,
    'title': title,
    'description': description,
    'runtime': runtime,
    'entrypoint': entrypoint,
    'capabilities': capabilities,
    'sha256': {'scene.glb': sceneSha256},
    'camera': {'position': cameraPosition, 'target': cameraTarget},
    if (isV2 && extensions.isNotEmpty) 'extensions': extensions,
  };

  static List<double> _vector(Object? value) {
    if (value is! List ||
        value.length != 3 ||
        value.any((v) => v is! num || !v.isFinite || v.abs() > 10000)) {
      throw const FormatException(
        'Camera vectors require three finite values within ±10000.',
      );
    }
    return value.map((v) => (v as num).toDouble()).toList();
  }
}
