import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'vrlz_world_bundle.dart';
import 'vrlz_world_manifest.dart';
import 'vrz_glb.dart' show decodeVrzJson;

/// Storage belongs to the host. The same viewer can use native durable files or
/// a web persistence implementation without importing dart:io.
abstract interface class VrlzWorldPersistence {
  Future<Uint8List?> read(String experienceId);
  Future<void> write(String experienceId, Uint8List data);
}

final class VrlzWorldPose {
  const VrlzWorldPose({
    required this.x,
    required this.y,
    required this.z,
    required this.yaw,
  });
  final double x, y, z, yaw;
  List<double> get position => [x, y, z];
  Map<String, dynamic> toJson() => {'position': position, 'yaw': yaw};

  factory VrlzWorldPose.fromJson(Map<String, dynamic> json) {
    if (json.length != 2 ||
        !json.containsKey('position') ||
        !json.containsKey('yaw')) {
      throw const FormatException('Invalid pose.');
    }
    final p = vrlzWorldVector(json['position']);
    return VrlzWorldPose(
      x: p[0],
      y: p[1],
      z: p[2],
      yaw: vrlzWorldYaw(json['yaw']),
    );
  }
}

/// Renderer-independent navigation and small user-owned visit state.
/// Switching releases no resources here: the viewer owns exactly one reader.
final class VrlzWorldSession {
  VrlzWorldSession(this.bundle) {
    _currentWorld = bundle.manifest.entrypoint;
    final world = bundle.manifest.world(_currentWorld);
    _visits[_currentWorld] = VrlzWorldPose(
      x: world.spawn[0],
      y: world.spawn[1],
      z: world.spawn[2],
      yaw: world.yaw,
    );
  }
  final VrlzWorldBundle bundle;
  late String _currentWorld;
  final _visits = <String, VrlzWorldPose>{};
  int _sequence = 0;
  int _lastSnapshotMicros = 0;
  String get currentWorld => _currentWorld;
  VrlzWorldPose get pose => _visits[_currentWorld]!;
  Map<String, VrlzWorldPose> get visits => Map.unmodifiable(_visits);

  /// Opens a declared destination selected explicitly by the host, e.g. a Home
  /// storefront. A previous visit keeps its pose; a first visit uses the world's
  /// authored spawn and heading. This does not add a portal or interpret a route.
  /// Unknown destinations or invalid placements return false without changing
  /// the current world, visits or save sequence.
  bool selectWorld(String alias) {
    VrlzWorldEntry? target;
    for (final world in bundle.manifest.worlds) {
      if (world.alias == alias) target = world;
    }
    if (target == null) return false;
    final nextPose =
        _visits[alias] ??
        VrlzWorldPose(
          x: target.spawn[0],
          y: target.spawn[1],
          z: target.spawn[2],
          yaw: target.yaw,
        );
    if (!bundle.containsPosition(alias, nextPose.position)) return false;
    if (_currentWorld == alias) return true;
    _visits.putIfAbsent(alias, () => nextPose);
    _currentWorld = alias;
    _sequence++;
    return true;
  }

  /// Yaw can accumulate during movement; normalize before durable validation.
  void updatePose(VrlzWorldPose value) {
    if (!value.yaw.isFinite) throw const FormatException('Invalid pose yaw.');
    final p = vrlzWorldVector(value.position);
    if (!bundle.containsPosition(_currentWorld, p)) {
      throw const FormatException('Pose lies outside declared world regions.');
    }
    var yaw = value.yaw % (2 * math.pi);
    if (yaw > math.pi) yaw -= 2 * math.pi;
    final previous = pose;
    if (previous.x == value.x &&
        previous.y == value.y &&
        previous.z == value.z &&
        previous.yaw == yaw) {
      return;
    }
    _visits[_currentWorld] = VrlzWorldPose(x: p[0], y: p[1], z: p[2], yaw: yaw);
    _sequence++;
  }

  /// Declared portals alone can travel. Revisits resume their last pose; first
  /// arrivals use the portal's authored spawn and heading. Cycles are allowed.
  bool enterPortal(String id) {
    VrlzWorldPortal? target;
    for (final portal in bundle.manifest.portals) {
      if (portal.id == id && portal.from == _currentWorld) target = portal;
    }
    if (target == null) return false;
    final p = pose;
    final at = target.position;
    final distance2 =
        math.pow(p.x - at[0], 2) +
        math.pow(p.y - at[1], 2) +
        math.pow(p.z - at[2], 2);
    if (distance2 > 4.5 * 4.5) return false;
    _currentWorld = target.to;
    _visits.putIfAbsent(
      _currentWorld,
      () => VrlzWorldPose(
        x: target!.arrival[0],
        y: target.arrival[1],
        z: target.arrival[2],
        yaw: target.yaw,
      ),
    );
    _sequence++;
    return true;
  }

  Uint8List encodeSnapshot() {
    _lastSnapshotMicros = math.max(
      DateTime.now().microsecondsSinceEpoch,
      _lastSnapshotMicros + 1,
    );
    final state = <String, dynamic>{
      'schema': 1,
      'experienceId': bundle.manifest.id,
      'manifestSha256': bundle.manifestSha256,
      'contentRevision': bundle.manifest.revision,
      'sequence': _sequence,
      'savedAtMicros': _lastSnapshotMicros,
      'currentWorld': _currentWorld,
      'visits': {
        for (final entry in _visits.entries) entry.key: entry.value.toJson(),
      },
    };
    return VrlzWorldSnapshot.encode(state);
  }

  /// Invalid, stale-content or corrupted saves leave this session untouched.
  bool restoreSnapshot(Uint8List bytes) {
    try {
      final state = VrlzWorldSnapshot.decode(bytes);
      if (state['experienceId'] != bundle.manifest.id ||
          state['manifestSha256'] != bundle.manifestSha256 ||
          state['contentRevision'] != bundle.manifest.revision) {
        return false;
      }
      final aliases = bundle.manifest.worlds
          .map((world) => world.alias)
          .toSet();
      final current = state['currentWorld'] as String;
      final values = state['visits'] as Map<String, dynamic>;
      if (!aliases.contains(current) ||
          !values.containsKey(current) ||
          !values.keys.every(aliases.contains)) {
        return false;
      }
      final restored = <String, VrlzWorldPose>{};
      for (final entry in values.entries) {
        final p = VrlzWorldPose.fromJson(entry.value as Map<String, dynamic>);
        if (!bundle.containsPosition(entry.key, p.position)) return false;
        restored[entry.key] = p;
      }
      _visits
        ..clear()
        ..addAll(restored);
      _currentWorld = current;
      _sequence = state['sequence'] as int;
      _lastSnapshotMicros = state['savedAtMicros'] as int;
      return true;
    } on FormatException {
      return false;
    }
  }
}

/// Checksums detect corruption, not malicious writers or publisher identity.
/// This bounded envelope is shared with persistence before any filesystem write.
abstract final class VrlzWorldSnapshot {
  static const maxBytes = 16 * 1024;
  static Uint8List encode(Map<String, dynamic> state) {
    final payload = utf8.encode(jsonEncode(state));
    final result = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'state': state,
          'sha256': crypto.sha256.convert(payload).toString(),
        }),
      ),
    );
    decode(result);
    return result;
  }

  static Map<String, dynamic> decode(Uint8List bytes) {
    if (bytes.length > maxBytes) {
      throw const FormatException('Save exceeds budget.');
    }
    final envelope = decodeVrzJson(bytes);
    if (envelope.length != 2 ||
        envelope['state'] is! Map<String, dynamic> ||
        envelope['sha256'] is! String) {
      throw const FormatException('Invalid save.');
    }
    final state = envelope['state'] as Map<String, dynamic>;
    final digest = crypto.sha256
        .convert(utf8.encode(jsonEncode(state)))
        .toString();
    const keys = {
      'schema',
      'experienceId',
      'manifestSha256',
      'contentRevision',
      'sequence',
      'savedAtMicros',
      'currentWorld',
      'visits',
    };
    if (digest != envelope['sha256'] ||
        state.length != keys.length ||
        !state.keys.every(keys.contains) ||
        state['schema'] is! int ||
        state['schema'] != 1 ||
        state['experienceId'] is! String ||
        !RegExp(
          r'^[a-z0-9][a-z0-9._-]{0,95}$',
        ).hasMatch(state['experienceId']) ||
        state['manifestSha256'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(state['manifestSha256']) ||
        state['contentRevision'] is! String ||
        (state['contentRevision'] as String).isEmpty ||
        (state['contentRevision'] as String).length > 64 ||
        state['currentWorld'] is! String ||
        state['sequence'] is! int ||
        (state['sequence'] as int) < 0 ||
        (state['sequence'] as int) > 9007199254740991 ||
        state['savedAtMicros'] is! int ||
        (state['savedAtMicros'] as int) < 0 ||
        (state['savedAtMicros'] as int) > 9007199254740991 ||
        state['visits'] is! Map<String, dynamic>) {
      throw const FormatException('Invalid or corrupted save state.');
    }
    final visits = state['visits'] as Map<String, dynamic>;
    if (visits.isEmpty ||
        visits.length > VrlzWorldManifest.maxWorlds ||
        !visits.containsKey(state['currentWorld'])) {
      throw const FormatException('Invalid saved world visits.');
    }
    for (final entry in visits.entries) {
      if (!RegExp(r'^[a-z][a-z0-9_-]{0,31}$').hasMatch(entry.key) ||
          entry.value is! Map<String, dynamic>) {
        throw const FormatException('Invalid saved visit.');
      }
      VrlzWorldPose.fromJson(entry.value as Map<String, dynamic>);
    }
    return state;
  }
}
