/// A reference to one demo already compiled into the host application.
///
/// This manifest grants no permissions, supplies no code and does not establish
/// that the receiving host has this demo. The host must resolve [demoId] against
/// its own explicit catalog before offering to launch it.
final class VrlzBuiltinManifest {
  const VrlzBuiltinManifest._({
    required this.id,
    required this.title,
    required this.description,
    required this.demoId,
  });

  static const supportedFormatVersion = 2;
  static const supportedRuntime = 'vrlizate.builtin.v1';
  static const supportedCapability = 'host.builtin';

  final String id;
  final String title;
  final String description;
  final String demoId;
  int get formatVersion => supportedFormatVersion;
  String get runtime => supportedRuntime;
  String get entrypoint => demoId;
  List<String> get capabilities => const [supportedCapability];

  factory VrlzBuiltinManifest.fromJson(Map<String, Object?> json) {
    const fields = {
      'formatVersion',
      'id',
      'title',
      'description',
      'runtime',
      'entrypoint',
      'capabilities',
      'sha256',
    };
    if (json.keys.any((key) => !fields.contains(key))) {
      throw const FormatException('Unknown builtin VRLZ manifest field.');
    }
    if (json['formatVersion'] is! int ||
        json['formatVersion'] != supportedFormatVersion ||
        json['runtime'] != supportedRuntime) {
      throw const FormatException(
        'Unsupported builtin VRLZ version or runtime.',
      );
    }
    final capabilities = json['capabilities'];
    if (capabilities is! List ||
        capabilities.length != 1 ||
        capabilities.single != supportedCapability) {
      throw const FormatException('Unsupported builtin VRLZ capabilities.');
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
    final demoId = json['entrypoint'];
    if (demoId is! String ||
        demoId.length > 128 ||
        RegExp(r'^[a-z][a-z0-9]*(?:[_-][a-z0-9]+)*$').stringMatch(demoId) !=
            demoId) {
      throw const FormatException(
        'Builtin VRLZ entrypoint must be a lowercase demo identifier.',
      );
    }
    final hashes = json['sha256'];
    if (hashes is! Map || hashes.isNotEmpty) {
      throw const FormatException(
        'Builtin VRLZ requires an empty sha256 object.',
      );
    }
    return VrlzBuiltinManifest._(
      id: id,
      title: title,
      description: description,
      demoId: demoId,
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
    'sha256': <String, String>{},
  };
}
