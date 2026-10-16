import 'dart:convert';

/// Metadata for a bounded NES cartridge interpreted by a host-owned core.
///
/// [license] retains the publisher's complete license notice. This declaration
/// and the ROM hash do not establish authorship or redistribution permission.
final class VrlzNesManifest {
  const VrlzNesManifest._({
    required this.id,
    required this.title,
    required this.description,
    required this.romSha256,
    required this.license,
    required this.sourceUrl,
  });

  static const supportedFormatVersion = 3;
  static const supportedRuntime = 'vrlizate.nes.v1';
  static const supportedCapability = 'emulator.nes';
  static const maxLicenseBytes = 16 * 1024;

  final String id, title, description, romSha256, license, sourceUrl;
  int get formatVersion => supportedFormatVersion;
  String get runtime => supportedRuntime;
  String get entrypoint => 'game.nes';
  List<String> get capabilities => const [supportedCapability];

  factory VrlzNesManifest.fromJson(Map<String, Object?> json) {
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
      'sourceUrl',
    };
    if (json.keys.any((key) => !fields.contains(key))) {
      throw const FormatException('Unknown NES VRLZ manifest field.');
    }
    if (json['formatVersion'] is! int ||
        json['formatVersion'] != supportedFormatVersion ||
        json['runtime'] != supportedRuntime ||
        json['entrypoint'] != 'game.nes') {
      throw const FormatException('Unsupported NES VRLZ version or runtime.');
    }
    final capabilities = json['capabilities'];
    if (capabilities is! List ||
        capabilities.length != 1 ||
        capabilities.single != supportedCapability) {
      throw const FormatException('Unsupported NES VRLZ capabilities.');
    }
    final id = json['id'];
    if (id is! String ||
        id.length > 128 ||
        RegExp(r'^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)+$').stringMatch(id) != id) {
      throw const FormatException(
        'VRLZ id must be a lowercase namespaced identifier.',
      );
    }
    final title = json['title'];
    final description = json['description'] ?? '';
    if (title is! String ||
        title.trim().isEmpty ||
        title.length > 80 ||
        description is! String ||
        description.length > 512) {
      throw const FormatException('Invalid VRLZ title or description.');
    }
    final hashes = json['sha256'];
    final hash = hashes is Map ? hashes['game.nes'] : null;
    if (hashes is! Map ||
        hashes.length != 1 ||
        hash is! String ||
        RegExp(r'^[a-f0-9]{64}$').stringMatch(hash) != hash) {
      throw const FormatException(
        'NES VRLZ requires exactly the game.nes SHA-256.',
      );
    }
    final license = json['license'];
    if (license is! String ||
        license.trim().length < 32 ||
        utf8.encode(license).length > maxLicenseBytes ||
        RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]').hasMatch(license)) {
      throw const FormatException(
        'NES VRLZ requires a full license notice within 16 KiB.',
      );
    }
    final sourceUrl = json['sourceUrl'];
    final source = sourceUrl is String ? Uri.tryParse(sourceUrl) : null;
    if (sourceUrl is! String ||
        sourceUrl.length > 2048 ||
        RegExp(r'\s').hasMatch(sourceUrl) ||
        source == null ||
        source.scheme != 'https' ||
        source.host.isEmpty ||
        source.userInfo.isNotEmpty ||
        source.hasFragment) {
      throw const FormatException(
        'NES sourceUrl must be an absolute HTTPS URL without credentials or fragment.',
      );
    }
    return VrlzNesManifest._(
      id: id,
      title: title,
      description: description,
      romSha256: hash,
      license: license,
      sourceUrl: sourceUrl,
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
    'sha256': {'game.nes': romSha256},
    'license': license,
    'sourceUrl': sourceUrl,
  };
}
