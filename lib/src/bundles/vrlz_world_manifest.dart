import 'dart:math' as math;

/// Closed data contract for the initial portable-worlds beta runtime.
final class VrlzWorldManifest {
  VrlzWorldManifest._(
    this.id,
    this.title,
    this.description,
    this.revision,
    this.entrypoint,
    this.worlds,
    this.portals,
  );

  static const runtime = 'vrlizate.worlds.v1';
  // Only the selected world prepares GPU resources; the archive still has a
  // 32 MiB aggregate cap. Catalog capacity is independent of the selected
  // world's unchanged resident-region, geometry and texture budgets.
  static const maxWorlds = 32;
  static const maxPortals = 64;
  final String id, title, description, revision, entrypoint;
  final List<VrlzWorldEntry> worlds;
  final List<VrlzWorldPortal> portals;

  VrlzWorldEntry world(String alias) => worlds.firstWhere(
    (world) => world.alias == alias,
    orElse: () => throw ArgumentError.value(alias, 'alias', 'Unknown world'),
  );

  factory VrlzWorldManifest.fromJson(Map<String, dynamic> json) {
    _keys(json, const {
      'formatVersion',
      'id',
      'title',
      'description',
      'runtime',
      'entrypoint',
      'capabilities',
      'revision',
      'worlds',
      'portals',
    });
    if (json['formatVersion'] is! int ||
        json['formatVersion'] != 1 ||
        json['runtime'] != runtime ||
        json['capabilities'] is! List ||
        (json['capabilities'] as List).length != 1 ||
        (json['capabilities'] as List).single != 'worlds.local') {
      _fail('Unsupported worlds runtime or capabilities.');
    }
    final id = _identifier(json['id']);
    final title = _text(json['title'], 96);
    final description = _text(json['description'], 512, empty: true);
    final revision = _text(json['revision'], 64);
    final entrypoint = _alias(json['entrypoint']);
    final rawWorlds = _list(json['worlds'], maxWorlds);
    if (rawWorlds.isEmpty) _fail('An experience needs a world.');
    final worlds = rawWorlds
        .map((raw) => VrlzWorldEntry._parse(_map(raw)))
        .toList();
    final aliases = worlds.map((world) => world.alias).toSet();
    if (aliases.length != worlds.length ||
        worlds.map((world) => world.id).toSet().length != worlds.length ||
        !aliases.contains(entrypoint)) {
      _fail('Duplicate or unknown world.');
    }
    final portals = _list(
      json['portals'],
      maxPortals,
    ).map((raw) => VrlzWorldPortal._parse(_map(raw))).toList();
    if (portals.map((portal) => portal.id).toSet().length != portals.length) {
      _fail('Duplicate portal identifier.');
    }
    for (final portal in portals) {
      if (portal.from == portal.to ||
          !aliases.contains(portal.from) ||
          !aliases.contains(portal.to)) {
        _fail('Invalid portal connection.');
      }
    }
    // Every included world must be reachable from the declared entrypoint.
    final reachable = {entrypoint};
    var changed = true;
    while (changed) {
      changed = false;
      for (final portal in portals) {
        if (reachable.contains(portal.from) && reachable.add(portal.to)) {
          changed = true;
        }
      }
    }
    if (reachable.length != worlds.length) _fail('Unreachable included world.');
    return VrlzWorldManifest._(
      id,
      title,
      description,
      revision,
      entrypoint,
      List.unmodifiable(worlds),
      List.unmodifiable(portals),
    );
  }

  Map<String, dynamic> toJson() => {
    'formatVersion': 1,
    'id': id,
    'title': title,
    'description': description,
    'runtime': runtime,
    'entrypoint': entrypoint,
    'capabilities': ['worlds.local'],
    'revision': revision,
    'worlds': worlds.map((world) => world.toJson()).toList(),
    'portals': portals.map((portal) => portal.toJson()).toList(),
  };
}

final class VrlzWorldEntry {
  VrlzWorldEntry._(
    this.alias,
    this.id,
    this.file,
    this.sha256,
    this.indexSha256,
    this.spawn,
    this.yaw,
  );
  final String alias, id, file, sha256, indexSha256;
  final List<double> spawn;
  final double yaw;

  factory VrlzWorldEntry._parse(Map<String, dynamic> json) {
    _keys(json, const {
      'alias',
      'id',
      'file',
      'sha256',
      'indexSha256',
      'spawn',
      'yaw',
    });
    final alias = _alias(json['alias']);
    if (json['file'] != 'world_$alias.vrlw') _fail('Unsafe world filename.');
    return VrlzWorldEntry._(
      alias,
      _identifier(json['id']),
      json['file'] as String,
      _digest(json['sha256']),
      _digest(json['indexSha256']),
      vrlzWorldVector(json['spawn']),
      vrlzWorldYaw(json['yaw']),
    );
  }

  Map<String, dynamic> toJson() => {
    'alias': alias,
    'id': id,
    'file': file,
    'sha256': sha256,
    'indexSha256': indexSha256,
    'spawn': spawn,
    'yaw': yaw,
  };
}

final class VrlzWorldPortal {
  VrlzWorldPortal._(
    this.id,
    this.from,
    this.to,
    this.position,
    this.arrival,
    this.yaw,
    this.label,
  );
  final String id, from, to, label;
  final List<double> position, arrival;
  final double yaw;

  factory VrlzWorldPortal._parse(Map<String, dynamic> json) {
    _keys(json, const {
      'id',
      'from',
      'to',
      'position',
      'arrival',
      'yaw',
      'label',
    });
    return VrlzWorldPortal._(
      _identifier(json['id']),
      _alias(json['from']),
      _alias(json['to']),
      vrlzWorldVector(json['position']),
      vrlzWorldVector(json['arrival']),
      vrlzWorldYaw(json['yaw']),
      _text(json['label'], 96),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'from': from,
    'to': to,
    'position': position,
    'arrival': arrival,
    'yaw': yaw,
    'label': label,
  };
}

/// Shared strict numeric rules used by durable state and the manifest.
List<double> vrlzWorldVector(Object? value) {
  if (value is! List || value.length != 3) _fail('Expected a 3D coordinate.');
  final result = <double>[];
  for (final component in value) {
    if (component is! num || !component.isFinite || component.abs() > 1000000) {
      _fail('Non-finite or out-of-range coordinate.');
    }
    result.add(component.toDouble());
  }
  return List.unmodifiable(result);
}

double vrlzWorldYaw(Object? value) {
  if (value is! num || !value.isFinite || value.abs() > 2 * math.pi) {
    _fail('Non-finite or out-of-range yaw.');
  }
  return value.toDouble();
}

void _keys(Map<String, dynamic> json, Set<String> allowed) {
  if (json.length != allowed.length || !json.keys.every(allowed.contains)) {
    _fail('Missing or unsupported manifest field.');
  }
}

Map<String, dynamic> _map(Object? value) {
  if (value is! Map<String, dynamic>) _fail('Expected an object.');
  return value;
}

List<dynamic> _list(Object? value, int max) {
  if (value is! List || value.length > max) {
    _fail('List exceeds profile budget.');
  }
  return value;
}

String _text(Object? value, int max, {bool empty = false}) {
  if (value is! String ||
      value.length > max ||
      (!empty && value.trim().isEmpty) ||
      value.codeUnits.any((c) => c < 32 || c == 127)) {
    _fail('Invalid text field.');
  }
  return value;
}

String _identifier(Object? value) {
  if (value is! String ||
      !RegExp(r'^[a-z0-9][a-z0-9._-]{0,95}$').hasMatch(value)) {
    _fail('Invalid identifier.');
  }
  return value;
}

String _alias(Object? value) {
  if (value is! String || !RegExp(r'^[a-z][a-z0-9_-]{0,31}$').hasMatch(value)) {
    _fail('Invalid world alias.');
  }
  return value;
}

String _digest(Object? value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    _fail('Invalid SHA-256 digest.');
  }
  return value;
}

Never _fail(String message) => throw FormatException('VRLZ worlds: $message');
