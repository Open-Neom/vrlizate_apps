import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math.dart' as vm;

/// Closed Catmull-Rom route, resampled once at equal arc-length intervals.
///
/// Sampling is O(1), writes into caller-owned storage and never searches the
/// route. The finite table is an approximation, not navigation/pathfinding.
/// Curved corners can extend beyond the authored waypoints; [boundsCenter] and
/// [boundsRadius] include the complete table actually used for rendering.
final class VrlwPathSampler {
  VrlwPathSampler(List<List<double>> waypoints) {
    if (waypoints.length < 3 ||
        waypoints.length > 16 ||
        waypoints.any(
          (p) => p.length != 3 || p.any((v) => !v.isFinite || v.abs() > 32),
        )) {
      throw const FormatException('Invalid bounded motion route.');
    }
    final count = waypoints.length;
    for (var i = 0; i < count; i++) {
      final a = waypoints[i], b = waypoints[(i + 1) % count];
      if (a[0] == b[0] && a[1] == b[1] && a[2] == b[2]) {
        throw const FormatException('Motion route has a duplicate edge.');
      }
    }
    final rawCount = count * samplesPerSegment;
    final raw = Float64List((rawCount + 1) * 3);
    final cumulative = Float64List(rawCount + 1);
    for (var i = 0; i < rawCount; i++) {
      final segment = i ~/ samplesPerSegment;
      final t = (i % samplesPerSegment) / samplesPerSegment;
      final a = waypoints[(segment + count - 1) % count];
      final b = waypoints[segment];
      final c = waypoints[(segment + 1) % count];
      final d = waypoints[(segment + 2) % count];
      for (var axis = 0; axis < 3; axis++) {
        raw[i * 3 + axis] =
            .5 *
            (2 * b[axis] +
                (-a[axis] + c[axis]) * t +
                (2 * a[axis] - 5 * b[axis] + 4 * c[axis] - d[axis]) * t * t +
                (-a[axis] + 3 * b[axis] - 3 * c[axis] + d[axis]) * t * t * t);
      }
    }
    for (var axis = 0; axis < 3; axis++) {
      raw[rawCount * 3 + axis] = raw[axis];
    }
    for (var i = 1; i <= rawCount; i++) {
      cumulative[i] =
          cumulative[i - 1] +
          _length(
            raw[i * 3] - raw[(i - 1) * 3],
            raw[i * 3 + 1] - raw[(i - 1) * 3 + 1],
            raw[i * 3 + 2] - raw[(i - 1) * 3 + 2],
          );
    }
    length = cumulative.last;
    if (!length.isFinite || length <= 0) {
      throw const FormatException('Motion route has no finite length.');
    }
    var edge = 1;
    var minX = double.infinity, minY = double.infinity, minZ = double.infinity;
    var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    var maxZ = double.negativeInfinity;
    for (var i = 0; i < sampleCount; i++) {
      final distance = length * (i / sampleCount);
      while (edge < rawCount && cumulative[edge] < distance) {
        edge++;
      }
      final span = cumulative[edge] - cumulative[edge - 1];
      final t = span > 0 ? (distance - cumulative[edge - 1]) / span : 0.0;
      for (var axis = 0; axis < 3; axis++) {
        final a = raw[(edge - 1) * 3 + axis];
        _positions[i * 3 + axis] = a + (raw[edge * 3 + axis] - a) * t;
      }
      final x = _positions[i * 3], y = _positions[i * 3 + 1];
      final z = _positions[i * 3 + 2];
      minX = math.min(minX, x);
      maxX = math.max(maxX, x);
      minY = math.min(minY, y);
      maxY = math.max(maxY, y);
      minZ = math.min(minZ, z);
      maxZ = math.max(maxZ, z);
    }
    boundsCenter.setValues(
      (minX + maxX) / 2,
      (minY + maxY) / 2,
      (minZ + maxZ) / 2,
    );
    boundsRadius = _length(maxX - minX, maxY - minY, maxZ - minZ) / 2;
    // Heading only follows the horizontal tangent; vertical displacement never
    // tilts a pedestrian or vehicle. Resolve vertical/degenerate spans once.
    var previousYaw = 0.0;
    for (var i = 0; i < sampleCount; i++) {
      final a = (i + sampleCount - 1) % sampleCount;
      final b = (i + 1) % sampleCount;
      final dx = _positions[b * 3] - _positions[a * 3];
      final dz = _positions[b * 3 + 2] - _positions[a * 3 + 2];
      if (dx != 0 || dz != 0) previousYaw = math.atan2(-dx, -dz);
      _heading[i] = previousYaw;
    }
  }

  static const samplesPerSegment = 32;
  static const sampleCount = 512;
  final _positions = Float64List(sampleCount * 3);
  final _heading = Float64List(sampleCount);
  final boundsCenter = vm.Vector3.zero();
  late final double boundsRadius;
  late final double length;

  /// Phase is one full loop. Invalid inputs safely retain the first pose.
  void writeTransform(double phase, vm.Matrix4 output, {bool orient = true}) {
    final wrapped = phase.isFinite ? phase - phase.floorToDouble() : 0.0;
    final sample = wrapped * sampleCount;
    final whole = sample.floor();
    final a = whole % sampleCount;
    final b = (a + 1) % sampleCount;
    final t = sample - whole;
    output.setIdentity();
    output.setTranslationRaw(
      _positions[a * 3] + (_positions[b * 3] - _positions[a * 3]) * t,
      _positions[a * 3 + 1] +
          (_positions[b * 3 + 1] - _positions[a * 3 + 1]) * t,
      _positions[a * 3 + 2] +
          (_positions[b * 3 + 2] - _positions[a * 3 + 2]) * t,
    );
    if (orient) {
      var delta = _heading[b] - _heading[a];
      if (delta > math.pi) delta -= 2 * math.pi;
      if (delta < -math.pi) delta += 2 * math.pi;
      output.rotateY(_heading[a] + delta * t);
    }
  }

  static double _length(double x, double y, double z) {
    final scale = math.max(x.abs(), math.max(y.abs(), z.abs()));
    if (scale == 0) return 0;
    return scale *
        math.sqrt(
          (x / scale) * (x / scale) +
              (y / scale) * (y / scale) +
              (z / scale) * (z / scale),
        );
  }
}
