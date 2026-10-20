/// A closed index of a browser build. This profile executes web code only in
/// a host-supplied browser sandbox; it does not load Dart AOT/native modules.
final class VrlzWebGameManifest {
  VrlzWebGameManifest._({
    required this.id,
    required this.title,
    required this.description,
    required this.revision,
    required this.entrypoint,
    required this.contentBaseUrl,
    required this.controllerProfile,
    required this.controls,
    required this.license,
    required this.assetNotice,
    required this.sourceUrl,
    required this.licenseUrl,
    required this.sourceArchiveUrl,
    required this.units,
    required this.files,
    required this.networkOrigins,
    required this.requirements,
    required this.viewportWidth,
    required this.viewportHeight,
  });

  static const runtime = 'vrlizate.webgame.v1';
  static const maxIndexBytes = 512 * 1024;
  static const maxFiles = 4096;
  static const maxFileBytes = 64 * 1024 * 1024;
  static const maxTotalBytes = 1024 * 1024 * 1024;
  static const controllerProfiles = {
    'dpad',
    'platformer',
    'pointer',
    'chess',
    'pinball',
    'rpg',
    'driving',
  };

  /// Browser capabilities that a host must check before loading game code.
  static const browserRequirements = {
    'wasm-gc',
    'webgl2',
    'cross-origin-isolation',
  };
  static const mediaTypes = {
    'text/html',
    'text/css',
    'text/plain',
    'text/javascript',
    'application/javascript',
    'application/wasm',
    'application/json',
    'application/octet-stream',
    'image/png',
    'image/jpeg',
    'image/webp',
    'image/gif',
    'image/svg+xml',
    'image/avif',
    'font/woff',
    'font/woff2',
    'font/ttf',
    'font/otf',
    'audio/ogg',
    'audio/wav',
    'audio/mpeg',
    'audio/mp4',
    'video/mp4',
    'video/webm',
  };

  final String id, title, description, revision, entrypoint, controllerProfile;
  final String license, assetNotice;
  final Uri contentBaseUrl, sourceUrl, licenseUrl, sourceArchiveUrl;
  final Map<String, String> controls;
  final List<VrlzWebGameUnit> units;
  final List<VrlzWebGameFile> files;

  /// Declared exact HTTPS origins for CSP connect-src, never native permission.
  /// Hosts still decide whether a catalog is trusted to enable these origins.
  final List<Uri> networkOrigins;

  /// Optional bounded browser requirements, distinct from sandbox permissions.
  /// An empty list preserves compatibility with existing webgame v1 indices.
  final List<String> requirements;
  final int viewportWidth, viewportHeight;
  late final Map<String, VrlzWebGameFile> _filesByPath = Map.unmodifiable({
    for (final file in files) file.path: file,
  });
  int get byteLength => files.fold(0, (sum, file) => sum + file.byteLength);
  bool get portable => true;

  VrlzWebGameFile file(String path) {
    validatePath(path);
    return _filesByPath[path] ??
        (throw const FormatException(
          'The web build does not declare this file.',
        ));
  }

  VrlzWebGameUnit unit(String id) => units.firstWhere(
    (unit) => unit.id == id,
    orElse: () => throw const FormatException('Unknown web build unit.'),
  );
  Uri urlFor(VrlzWebGameFile file) => contentBaseUrl.resolve(file.path);

  factory VrlzWebGameManifest.fromJson(Map<String, Object?> json) {
    _keys(json, const {
      'formatVersion',
      'runtime',
      'capabilities',
      'id',
      'title',
      'description',
      'revision',
      'entrypoint',
      'contentBaseUrl',
      'controllerProfile',
      'controls',
      'license',
      'assetNotice',
      'sourceUrl',
      'licenseUrl',
      'sourceArchiveUrl',
      'units',
      'networkOrigins',
      'requirements',
      'viewportWidth',
      'viewportHeight',
    });
    if (json['formatVersion'] != 1 ||
        json['formatVersion'] is! int ||
        json['runtime'] != runtime ||
        json['capabilities'] is! List ||
        (json['capabilities'] as List).length != 1 ||
        (json['capabilities'] as List).single != 'web.sandbox') {
      _fail('Unsupported webgame runtime, format or capabilities.');
    }
    final id = _text(json['id'], 128);
    if (!(RegExp(r'^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)+$').stringMatch(id) ==
        id)) {
      _fail('Invalid webgame id.');
    }
    final title = _text(json['title'], 80);
    final description = _text(json['description'] ?? '', 512, empty: true);
    final revision = _text(json['revision'], 128);
    final entrypoint = _text(json['entrypoint'], 1024);
    validatePath(entrypoint);
    if (!entrypoint.endsWith('.html')) {
      _fail('Entrypoint must be declared HTML.');
    }
    final base = _url(json['contentBaseUrl'], local: true);
    final sourceArchive = _url(
      json['sourceArchiveUrl'],
      local: base.scheme == 'http',
    );
    if (sourceArchive.scheme == 'http' && sourceArchive.origin != base.origin) {
      _fail('Development source archive must use the same loopback origin.');
    }
    if (!base.path.endsWith('/') || base.hasQuery) {
      _fail('Content base must be a directory URL.');
    }
    for (final part in base.pathSegments.where((part) => part.isNotEmpty)) {
      if (part == '.' ||
          part == '..' ||
          part.contains('/') ||
          part.contains(r'\')) {
        _fail('Unsafe content base.');
      }
    }
    final profile = _text(json['controllerProfile'], 32);
    final viewportWidth = json['viewportWidth'] ?? 1280;
    final viewportHeight = json['viewportHeight'] ?? 720;
    if (viewportWidth is! int ||
        viewportHeight is! int ||
        viewportWidth < 240 ||
        viewportHeight < 240 ||
        viewportWidth > 1920 ||
        viewportHeight > 1920 ||
        viewportWidth * viewportHeight > 1920 * 1080) {
      _fail('Webgame viewport exceeds its pixel budget.');
    }
    final rawRequirements = json.containsKey('requirements')
        ? json['requirements']
        : const [];
    if (rawRequirements is! List || rawRequirements.length > 3) {
      _fail('Invalid browser requirements.');
    }
    final requirements = <String>[];
    for (final value in rawRequirements) {
      if (value is! String ||
          !browserRequirements.contains(value) ||
          requirements.contains(value)) {
        _fail('Browser requirements must be distinct supported capabilities.');
      }
      requirements.add(value);
    }
    final rawOrigins = json['networkOrigins'] ?? const [];
    if (rawOrigins is! List || rawOrigins.length > 8) {
      _fail('Invalid network origin allowlist.');
    }
    final origins = <Uri>[];
    for (final raw in rawOrigins) {
      final origin = _url(raw);
      if ((origin.path.isNotEmpty && origin.path != '/') ||
          origin.hasQuery ||
          origins.any((value) => value.origin == origin.origin)) {
        _fail('Network allowances must be distinct exact HTTPS origins.');
      }
      origins.add(Uri.parse(origin.origin));
    }
    if (!controllerProfiles.contains(profile)) {
      _fail('Unsupported controller profile.');
    }
    final rawControls = json['controls'] ?? const <String, Object?>{};
    if (rawControls is! Map<String, Object?> || rawControls.length > 14) {
      _fail('Invalid web input map.');
    }
    final controls = <String, String>{};
    const buttons = {
      'UP',
      'DOWN',
      'LEFT',
      'RIGHT',
      'A',
      'X',
      'Y',
      'L',
      'R',
      'GRIP',
      'START',
      'SELECT',
    };
    final keyCode = RegExp(
      r'^(?:Arrow(?:Up|Down|Left|Right)|Enter|Space|Tab|Escape|Backspace|Shift(?:Left|Right)|Control(?:Left|Right)|Key[A-Z]|Digit[0-9])$',
    );
    for (final entry in rawControls.entries) {
      if (!buttons.contains(entry.key) ||
          entry.value is! String ||
          keyCode.stringMatch(entry.value as String) != entry.value) {
        _fail('Unsafe web input binding.');
      }
      controls[entry.key] = entry.value as String;
    }
    final rawUnits = json['units'];
    if (rawUnits is! List || rawUnits.isEmpty || rawUnits.length > 128) {
      _fail('Invalid web units.');
    }
    final units = <VrlzWebGameUnit>[];
    final files = <VrlzWebGameFile>[];
    final ids = <String>{}, paths = <String>{};
    var total = 0;
    for (final raw in rawUnits) {
      if (raw is! Map<String, Object?>) _fail('Invalid web unit.');
      _keys(raw, const {'id', 'startup', 'files'});
      final unitId = _text(raw['id'], 80);
      if (RegExp(r'^[a-z][a-z0-9_-]*$').stringMatch(unitId) != unitId ||
          !ids.add(unitId) ||
          raw['startup'] is! bool) {
        _fail('Invalid or duplicate web unit.');
      }
      final rawFiles = raw['files'];
      if (rawFiles is! List ||
          rawFiles.isEmpty ||
          rawFiles.length > maxFiles - files.length) {
        _fail('Invalid web unit files.');
      }
      final unitFiles = <VrlzWebGameFile>[];
      for (final value in rawFiles) {
        if (value is! Map<String, Object?>) _fail('Invalid web file.');
        _keys(value, const {'path', 'byteLength', 'sha256', 'mediaType'});
        final path = _text(value['path'], 1024);
        validatePath(path);
        final size = value['byteLength'];
        final hash = value['sha256'];
        final mime = value['mediaType'];
        if (!paths.add(path.toLowerCase()) ||
            size is! int ||
            size < 0 ||
            size > maxFileBytes ||
            hash is! String ||
            hash.length != 64 ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash) ||
            mime is! String ||
            !mediaTypes.contains(mime)) {
          _fail('Invalid, duplicate or excessive web file.');
        }
        total += size;
        if (total > maxTotalBytes) {
          _fail('Web build exceeds total byte budget.');
        }
        final file = VrlzWebGameFile._(path, size, hash, mime, unitId);
        unitFiles.add(file);
        files.add(file);
      }
      units.add(
        VrlzWebGameUnit._(
          unitId,
          raw['startup'] as bool,
          List.unmodifiable(unitFiles),
        ),
      );
    }
    final entry = files.where((file) => file.path == entrypoint);
    if (entry.length != 1 ||
        entry.single.mediaType != 'text/html' ||
        entry.single.byteLength == 0 ||
        !units.singleWhere((unit) => unit.id == entry.single.unitId).startup) {
      _fail('Entrypoint must belong to a startup unit.');
    }
    return VrlzWebGameManifest._(
      id: id,
      title: title,
      description: description,
      revision: revision,
      entrypoint: entrypoint,
      contentBaseUrl: base,
      controllerProfile: profile,
      controls: Map.unmodifiable(controls),
      license: _text(json['license'], 256),
      assetNotice: _text(json['assetNotice'], 4096),
      sourceUrl: _url(json['sourceUrl']),
      licenseUrl: _url(json['licenseUrl']),
      sourceArchiveUrl: sourceArchive,
      units: List.unmodifiable(units),
      files: List.unmodifiable(files),
      networkOrigins: List.unmodifiable(origins),
      requirements: List.unmodifiable(requirements),
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
    );
  }

  Map<String, Object?> toJson() => {
    'formatVersion': 1,
    'runtime': runtime,
    'capabilities': ['web.sandbox'],
    if (requirements.isNotEmpty) 'requirements': requirements,
    'id': id,
    'title': title,
    'description': description,
    'revision': revision,
    'entrypoint': entrypoint,
    'contentBaseUrl': '$contentBaseUrl',
    'controllerProfile': controllerProfile,
    'controls': controls,
    'license': license,
    'assetNotice': assetNotice,
    'sourceUrl': '$sourceUrl',
    'licenseUrl': '$licenseUrl',
    'sourceArchiveUrl': '$sourceArchiveUrl',
    'networkOrigins': [for (final origin in networkOrigins) '$origin'],
    'viewportWidth': viewportWidth,
    'viewportHeight': viewportHeight,
    'units': [for (final unit in units) unit.toJson()],
  };

  static void validatePath(String path) {
    if (path.isEmpty ||
        path.length > 1024 ||
        path.startsWith('/') ||
        path.contains(r'\') ||
        path.contains('%') ||
        path
            .split('/')
            .any(
              (part) =>
                  part.isEmpty ||
                  part == '.' ||
                  part == '..' ||
                  RegExp(
                        r'^[A-Za-z0-9_@+-][A-Za-z0-9_.@+-]{0,127}$',
                      ).stringMatch(part) !=
                      part,
            )) {
      _fail('Web paths must be canonical relative portable paths.');
    }
  }
}

final class VrlzWebGameUnit {
  const VrlzWebGameUnit._(this.id, this.startup, this.files);
  final String id;
  final bool startup;
  final List<VrlzWebGameFile> files;
  int get byteLength => files.fold(0, (sum, file) => sum + file.byteLength);
  Map<String, Object?> toJson() => {
    'id': id,
    'startup': startup,
    'files': [for (final file in files) file.toJson()],
  };
}

final class VrlzWebGameFile {
  const VrlzWebGameFile._(
    this.path,
    this.byteLength,
    this.sha256,
    this.mediaType,
    this.unitId,
  );
  final String path, sha256, mediaType, unitId;
  final int byteLength;
  bool get portable => true;
  Map<String, Object?> toJson() => {
    'path': path,
    'byteLength': byteLength,
    'sha256': sha256,
    'mediaType': mediaType,
  };
}

Never _fail(String message) => throw FormatException(message);
String _text(Object? value, int max, {bool empty = false}) {
  if (value is! String ||
      value.length > max ||
      (!empty && value.trim().isEmpty) ||
      value.contains('\u0000')) {
    _fail('Invalid webgame text field.');
  }
  return value;
}

Uri _url(Object? value, {bool local = false}) {
  final text = _text(value, 2048);
  final uri = Uri.tryParse(text);
  if (uri == null ||
      uri.host.isEmpty ||
      uri.host.contains('*') ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      uri.port < 1 ||
      uri.port > 65535 ||
      (uri.scheme != 'https' &&
          !(local &&
              uri.scheme == 'http' &&
              const {'127.0.0.1', '::1'}.contains(uri.host)))) {
    _fail(
      'Webgame URLs require HTTPS (loopback development is opt-in at transport).',
    );
  }
  return uri;
}

void _keys(Map<String, Object?> value, Set<String> allowed) {
  if (value.keys.any((key) => !allowed.contains(key))) {
    _fail('Unknown webgame field.');
  }
}
