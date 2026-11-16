import 'dart:math' as math;
import 'dart:collection';

import 'package:vrlizate_scene/vrlizate_scene.dart' show VrDistanceBand;
import 'package:vrlizate_world/vrlizate_world.dart';

/// Immutable local-space bounds of the detailed, authored prototype.
/// The selector measures distance to this box, not its origin, so a large
/// structure stays detailed while the viewer is near one of its surfaces.
final class VrlwLodBounds {
  VrlwLodBounds({
    required this.minX,
    required this.minY,
    required this.minZ,
    required this.maxX,
    required this.maxY,
    required this.maxZ,
  }) {
    if (![minX, minY, minZ, maxX, maxY, maxZ].every((v) => v.isFinite) ||
        minX > maxX ||
        minY > maxY ||
        minZ > maxZ) {
      throw ArgumentError('LOD bounds must be finite and ordered.');
    }
  }

  final double minX, minY, minZ, maxX, maxY, maxZ;
}

/// Distance bands for one prototype. The first band is the complete model.
/// There is no invisible level: the last authored mesh remains visible.
final class VrlwLodPolicy {
  VrlwLodPolicy({
    required Iterable<double> minDistancesMeters,
    required this.bounds,
    this.hysteresisMeters = 2,
  }) : minDistancesMeters = List.unmodifiable(minDistancesMeters) {
    final distances = this.minDistancesMeters;
    if (distances.length < 2 ||
        distances.length > 3 ||
        distances.first != 0 ||
        !hysteresisMeters.isFinite ||
        hysteresisMeters < 0 ||
        distances.any((d) => !d.isFinite || d < 0)) {
      throw ArgumentError('Invalid portable LOD bands.');
    }
    for (var i = 1; i < distances.length; i++) {
      if (distances[i] - distances[i - 1] <= 2 * hysteresisMeters) {
        throw ArgumentError('LOD bands must be separated beyond hysteresis.');
      }
    }
    _bands = [
      for (final distance in distances.skip(1))
        VrDistanceBand(
          distanceMeters: distance,
          enterMarginMeters: hysteresisMeters,
          exitMarginMeters: hysteresisMeters,
          includeBoundary: false,
        ),
    ];
  }

  final List<double> minDistancesMeters;
  final VrlwLodBounds bounds;
  final double hysteresisMeters;
  late final List<VrDistanceBand> _bands;

  int levelAtDistance(double distanceMeters, {int? previousLevel}) {
    if (!distanceMeters.isFinite || distanceMeters < 0) {
      throw ArgumentError.value(distanceMeters, 'distanceMeters');
    }
    if (previousLevel == null) {
      var level = 0;
      while (level < _bands.length && !_bands[level].contains(distanceMeters)) {
        level++;
      }
      return level;
    }
    if (previousLevel < 0 || previousLevel >= minDistancesMeters.length) {
      throw ArgumentError.value(previousLevel, 'previousLevel');
    }
    var level = previousLevel;
    while (level < _bands.length &&
        !_bands[level].contains(distanceMeters, wasInside: true)) {
      level++;
    }
    while (level > 0 &&
        _bands[level - 1].contains(distanceMeters, wasInside: false)) {
      level--;
    }
    return level;
  }
}

/// CPU-only, retained LOD selection shared by the stereo scene's two eyes.
/// Evaluate using the rig's eye center, not once per rendered eye. Stable frames
/// do no per-entity distance work; normal motion is checked at most 10 Hz after
/// 25 cm of accumulated displacement. A jump of at least 4 m is handled at once.
final class VrlwLodSelector {
  final _policies = <String, VrlwLodPolicy>{};
  final _instances = <String, _Instance>{};
  final _changedPrototypeIds = <String>{};

  /// Read-only view of the prototypes that changed bands in the last update.
  /// Stable/throttled updates clear it; callers need rebuild only these batches.
  late final Set<String> changedPrototypeIds = UnmodifiableSetView(
    _changedPrototypeIds,
  );
  VrWorldPosition? _lastEye;
  double _elapsed = 0;
  bool _needsEvaluation = false;
  int _distanceEvaluations = 0;

  /// Diagnostic count of distance evaluations, not GPU draws or frames.
  int get distanceEvaluations => _distanceEvaluations;
  int get trackedEntityCount => _instances.length;

  void register(String prototypeId, VrlwLodPolicy policy) {
    if (_instances.isNotEmpty) {
      throw StateError('Register LOD policies before placing entities.');
    }
    _policies[prototypeId] = policy;
  }

  /// Preserve each surviving entity's band across region status changes.
  /// Entities with no LOD declaration always use their legacy complete model.
  void replaceEntities(Iterable<VrWorldEntity> entities) {
    final next = <String, _Instance>{};
    for (final entity in entities) {
      final policy = _policies[entity.prototypeId];
      if (policy == null) continue;
      final previous = _instances[entity.id];
      final level = identical(previous?.policy, policy)
          ? previous?.level
          : null;
      if (previous != null && identical(previous.transform, entity.transform)) {
        // Reuse immutable rotation values, never the mutable band snapshot.
        next[entity.id] = _Instance.withRotation(
          entity.prototypeId,
          entity.transform,
          policy,
          level,
          previous.cosine,
          previous.sine,
        );
      } else {
        next[entity.id] = _Instance(
          entity.prototypeId,
          entity.transform,
          policy,
          level,
        );
      }
    }
    _instances
      ..clear()
      ..addAll(next);
    _needsEvaluation = true;
  }

  int levelFor(String entityId) => _instances[entityId]?.level ?? 0;

  /// Returns true only when an entity changes its displayed geometry band.
  bool update(VrWorldPosition eye, double dt, {bool force = false}) {
    _changedPrototypeIds.clear();
    if (_instances.isEmpty) return false;
    _elapsed += dt.isFinite ? dt.clamp(0, 1) : 0;
    final moved2 = _lastEye?.distanceSquaredTo(eye) ?? double.infinity;
    if (!force &&
        !_needsEvaluation &&
        moved2 < 16 &&
        (_elapsed < .1 || moved2 < .0625)) {
      return false;
    }
    _elapsed = 0;
    _lastEye = eye;
    _needsEvaluation = false;
    var changed = false;
    for (final instance in _instances.values) {
      _distanceEvaluations++;
      final next = instance.policy.levelAtDistance(
        instance.distanceTo(eye),
        previousLevel: instance.level,
      );
      if (next != (instance.level ?? 0)) {
        changed = true;
        _changedPrototypeIds.add(instance.prototypeId);
      }
      instance.level = next;
    }
    return changed;
  }

  void clear() {
    _instances.clear();
    _changedPrototypeIds.clear();
    _policies.clear();
    _lastEye = null;
    _elapsed = 0;
    _needsEvaluation = false;
    _distanceEvaluations = 0;
  }
}

final class _Instance {
  _Instance(this.prototypeId, this.transform, this.policy, this.level)
    : cosine = math.cos(transform.yawRadians),
      sine = math.sin(transform.yawRadians);

  _Instance.withRotation(
    this.prototypeId,
    this.transform,
    this.policy,
    this.level,
    this.cosine,
    this.sine,
  );

  final String prototypeId;
  final VrWorldTransform transform;
  final VrlwLodPolicy policy;
  final double cosine, sine;
  int? level;

  double distanceTo(VrWorldPosition eye) {
    final dx = eye.x - transform.position.x;
    final dy = eye.y - transform.position.y;
    final dz = eye.z - transform.position.z;
    // Rotate the relative eye into the authored axes while keeping meters.
    // Scale bounds instead of dividing the eye by scale: the world contract
    // allows tiny positive scales, for which division would overflow.
    final x = cosine * dx - sine * dz;
    final y = dy;
    final z = sine * dx + cosine * dz;
    final bounds = policy.bounds;
    final scale = transform.scale;
    final xGap = _gap(x, bounds.minX * scale, bounds.maxX * scale);
    final yGap = _gap(y, bounds.minY * scale, bounds.maxY * scale);
    final zGap = _gap(z, bounds.minZ * scale, bounds.maxZ * scale);
    return math.sqrt(xGap * xGap + yGap * yGap + zGap * zGap);
  }

  static double _gap(double value, double min, double max) => value < min
      ? min - value
      : value > max
      ? value - max
      : 0;
}
