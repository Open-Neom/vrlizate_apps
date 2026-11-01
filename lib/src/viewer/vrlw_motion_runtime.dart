import 'package:vector_math/vector_math.dart' as vm;

import 'vrlw_world_activity.dart';

/// One retained renderer batch, updated in place with a single invalidation.
/// The writer must invoke its callback synchronously and keep the slot order.
final class VrlwMotionBatch {
  VrlwMotionBatch(this.writeTransforms);

  final void Function(void Function(List<vm.Matrix4> transforms))
  writeTransforms;
  final _instances = <_MotionInstance>[];
  late final _applyTransforms = _write;
  bool _needsWrite = false;

  void _write(List<vm.Matrix4> transforms) {
    for (final instance in _instances) {
      if (!instance.nearby || !instance.track.enabled) continue;
      transforms[instance.slot]
        ..setFrom(instance.entityTransform)
        ..multiply(instance.track.delta)
        ..multiply(instance.localTransform);
    }
  }
}

/// CPU animation scheduler shared by all the world's resident mesh batches.
///
/// Activity time and proximity still advance every viewer frame. Geometry is
/// written at the existing 30 Hz cadence; each shared motion is sampled once
/// per write tick and each changed batch is invalidated once. There is no
/// per-frame matrix allocation or additional distance-based quality reduction.
final class VrlwMotionRuntime {
  VrlwMotionRuntime(this.activity);

  final VrlwWorldActivity activity;
  final _tracks = <String, _MotionTrack>{};
  final _batches = <VrlwMotionBatch>{};
  final _nearby = <String>{};
  double _accumulator = 0;
  int _tick = 0;
  int _sampledDeltas = 0;

  /// CPU-only diagnostic: evaluated motion deltas, not draws or rendered FPS.
  int get sampledDeltas => _sampledDeltas;

  void add({
    required VrlwMotionBatch batch,
    required String motionId,
    required int slot,
    required vm.Matrix4 entityTransform,
    required vm.Matrix4 localTransform,
    required vm.Vector3 center,
    required double range,
  }) {
    final track = _tracks.putIfAbsent(motionId, () => _MotionTrack(motionId));
    batch._instances.add(
      _MotionInstance(
        track,
        slot,
        entityTransform,
        localTransform,
        center,
        range * range,
      ),
    );
    _batches.add(batch);
  }

  void update(vm.Vector3 eye, double dt) {
    _nearby.clear();
    for (final batch in _batches) {
      batch._needsWrite = false;
      for (final instance in batch._instances) {
        instance.nearby =
            eye.distanceToSquared(instance.center) <= instance.rangeSquared;
        if (instance.nearby) {
          _nearby.add(instance.track.id);
          batch._needsWrite = true;
        }
      }
    }
    activity.advance(dt, _nearby);
    _accumulator += dt.isFinite ? dt.clamp(0, .1) : 0;
    if (_accumulator < 1 / 30) return;
    _accumulator %= 1 / 30;
    _tick++;
    for (final batch in _batches) {
      if (!batch._needsWrite) continue;
      var hasEnabledInstance = false;
      for (final instance in batch._instances) {
        if (!instance.nearby) continue;
        final track = instance.track;
        if (track.checkedTick != _tick) {
          track.checkedTick = _tick;
          track.enabled = activity.motionEnabled(track.id);
          if (track.enabled) {
            activity.writeDelta(track.id, track.delta);
            _sampledDeltas++;
          }
        }
        if (track.enabled) hasEnabledInstance = true;
      }
      if (hasEnabledInstance) batch.writeTransforms(batch._applyTransforms);
    }
  }

  /// Region replacement releases slots, while keeping the animation cadence.
  /// The activity owns phases and interaction state across region/portal visits.
  void clear() {
    for (final batch in _batches) {
      batch._instances.clear();
      batch._needsWrite = false;
    }
    _batches.clear();
    _tracks.clear();
    _nearby.clear();
  }
}

final class _MotionTrack {
  _MotionTrack(this.id);
  final String id;
  final delta = vm.Matrix4.identity();
  bool enabled = false;
  int checkedTick = -1;
}

final class _MotionInstance {
  _MotionInstance(
    this.track,
    this.slot,
    this.entityTransform,
    this.localTransform,
    this.center,
    this.rangeSquared,
  );
  final _MotionTrack track;
  final int slot;
  final vm.Matrix4 entityTransform, localTransform;
  final vm.Vector3 center;
  final double rangeSquared;
  bool nearby = false;
}
