import 'dart:convert';

/// Metadata and integrity declaration for a portable retro 2.5D level.
/// A license declaration or hash does not establish ownership or a signature.
final class VrlzRetroManifest {
  const VrlzRetroManifest._({
    required this.id,
    required this.title,
    required this.description,
    required this.levelSha256,
    required this.license,
  });

  static const supportedFormatVersion = 4;
  static const supportedRuntime = 'vrlizate.retro2d.v1';
  static const supportedCapability = 'game.retro2d';
  static const maxLicenseBytes = 16 * 1024;
  final String id, title, description, levelSha256, license;
  int get formatVersion => supportedFormatVersion;
  String get runtime => supportedRuntime;
  String get entrypoint => 'level.json';
  List<String> get capabilities => const [supportedCapability];

  factory VrlzRetroManifest.fromJson(Map<String, Object?> json) {
    const fields = {
      'formatVersion',
      'id',
      'title',
      'description',
      'runtime',
      'entrypoint',
      'capabilities',
      'sha256',
      'license',
    };
    if (json.keys.any((key) => !fields.contains(key)) ||
        json['formatVersion'] is! int ||
        json['formatVersion'] != supportedFormatVersion ||
        json['runtime'] != supportedRuntime ||
        json['entrypoint'] != 'level.json') {
      throw const FormatException(
        'Unsupported retro VRLZ version, runtime or manifest field.',
      );
    }
    final capabilities = json['capabilities'];
    if (capabilities is! List ||
        capabilities.length != 1 ||
        capabilities.single != supportedCapability) {
      throw const FormatException('Unsupported retro VRLZ capabilities.');
    }
    final id = json['id'];
    final title = json['title'];
    final description = json['description'] ?? '';
    if (id is! String ||
        id.length > 128 ||
        RegExp(r'^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)+$').stringMatch(id) != id ||
        title is! String ||
        title.trim().isEmpty ||
        title.length > 80 ||
        description is! String ||
        description.length > 512) {
      throw const FormatException(
        'Invalid retro VRLZ identity or description.',
      );
    }
    final hashes = json['sha256'];
    final hash = hashes is Map ? hashes['level.json'] : null;
    if (hashes is! Map ||
        hashes.length != 1 ||
        hash is! String ||
        RegExp(r'^[a-f0-9]{64}$').stringMatch(hash) != hash) {
      throw const FormatException(
        'Retro VRLZ requires exactly the level.json SHA-256.',
      );
    }
    final license = json['license'];
    if (license is! String ||
        license.trim().length < 32 ||
        utf8.encode(license).length > maxLicenseBytes ||
        RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]').hasMatch(license)) {
      throw const FormatException(
        'Retro VRLZ requires a full license notice within 16 KiB.',
      );
    }
    return VrlzRetroManifest._(
      id: id,
      title: title,
      description: description,
      levelSha256: hash,
      license: license,
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
    'sha256': {'level.json': levelSha256},
    'license': license,
  };
}
