/// Immutable metadata for the deliberately small VRZ scene runtime.
final class VrzManifest {
  VrzManifest._({
    required this.id,
    required this.title,
    required this.description,
    required this.sceneSha256,
    required List<double> position,
    required List<double> target,
  }) : cameraPosition = List.unmodifiable(position),
       cameraTarget = List.unmodifiable(target);

  static const supportedRuntime = 'vrlizate.scene.v1';
  static const supportedCapability = 'scene.gltf2';
  final String id;
  final String title;
  final String description;
  final String sceneSha256;
  final List<double> cameraPosition;
  final List<double> cameraTarget;
  int get formatVersion => 1;
  String get entrypoint => 'scene.glb';
  String get entrypointName => entrypoint;
  String get runtime => supportedRuntime;
  List<String> get capabilities => const [supportedCapability];

  factory VrzManifest.fromJson(Map<String, Object?> json) {
    const fields = {
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
    if (json.keys.any((key) => !fields.contains(key))) {
      throw const FormatException('Unknown VRZ manifest field.');
    }
    if (json['formatVersion'] is! int ||
        json['formatVersion'] != 1 ||
        json['runtime'] != supportedRuntime ||
        json['entrypoint'] != 'scene.glb') {
      throw const FormatException(
        'Unsupported VRZ version, runtime or entrypoint.',
      );
    }
    final capabilities = json['capabilities'];
    if (capabilities is! List ||
        capabilities.length != 1 ||
        capabilities.single != supportedCapability) {
      throw const FormatException('Unsupported VRZ capabilities.');
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
      id: id,
      title: title,
      description: description,
      sceneSha256: hashes['scene.glb'] as String,
      position: position,
      target: target,
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
