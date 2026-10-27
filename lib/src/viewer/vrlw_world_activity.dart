import 'dart:math' as math;

import 'package:vector_math/vector_math.dart' as vm;
import 'package:vrlizate_world/vrlizate_world.dart';

import 'vrlw_path_sampler.dart';

/// Bounded interpretation of a world's validated actions; never executable code.
/// The viewer may retain this object across portal visits. State is local to
/// that viewer session; it does not change the immutable world or shared mesh.
final class VrlwWorldActivity {
  VrlwWorldActivity(VrlwBundleIndex index)
    : motions = {for (final m in index.motions) m.id: m},
      interactions = {for (final i in index.interactions) i.id: i},
      _motionEnabled = {
        for (final m in index.motions) m.id: m.initiallyEnabled,
      },
      _audioEnabled = {for (final a in index.audioEmitters) a.id: true},
      _paths = {
        for (final m in index.motions)
          if (m.kind == 'path') m.id: VrlwPathSampler(m.waypoints),
      };

  final Map<String, VrlwMotionSpec> motions;
  final Map<String, VrlwInteractionSpec> interactions;
  final Map<String, bool> _motionEnabled, _audioEnabled;
  final Map<String, VrlwPathSampler> _paths;
  final _phase = <String, double>{};
  final _lastActivation = <String, double>{};
  double _clock = 0;

  /// Retained across portal visits, frozen while this world is inactive.
  double get activeSeconds => _clock;

  VrlwPathSampler? pathFor(String id) => _paths[id];

  bool motionEnabled(String id) => _motionEnabled[id] ?? false;
  bool audioEnabled(String id) => _audioEnabled[id] ?? false;

  /// Only nearby, resident motion tracks consume animation time. Clamp a long
  /// gap on resume; disabled tracks keep their last pose rather than snapping.
  void advance(double dt, Set<String> nearby, {bool active = true}) {
    if (!active || !dt.isFinite || dt <= 0) return;
    final step = dt.clamp(0.0, .1);
    _clock += step;
    for (final id in nearby) {
      final motion = motions[id];
      if (motion == null || !motionEnabled(id)) continue;
      _phase[id] = ((_phase[id] ?? 0) + step) % motion.periodSeconds;
    }
  }

  bool canActivate(String id, vm.Vector3 eye) {
    final item = interactions[id];
    if (item == null || !eye.storage.every((v) => v.isFinite)) return false;
    return eye.distanceTo(vm.Vector3.array(item.position)) <= item.maxDistance;
  }

  /// Shared gaze, controller A, and tap use the same proximity/cooldown gate.
  /// Returns the accepted action so the host can update its audio and indicator.
  VrlwInteractionSpec? activate(String id, vm.Vector3 eye) {
    if (!canActivate(id, eye)) return null;
    final previous = _lastActivation[id];
    if (previous != null && _clock - previous < .4) return null;
    final item = interactions[id]!;
    switch (item.action) {
      case 'toggleMotion':
        _motionEnabled[item.target] = !motionEnabled(item.target);
      case 'toggleAudio':
        _audioEnabled[item.target] = !audioEnabled(item.target);
      default:
        return null;
    }
    _lastActivation[id] = _clock;
    return item;
  }

  bool indicatorEnabled(VrlwInteractionSpec item) =>
      item.action == 'toggleMotion'
      ? motionEnabled(item.target)
      : audioEnabled(item.target);

  /// Model-space delta around the authored pivot, before the entity pose.
  vm.Matrix4 delta(String id) {
    final transform = vm.Matrix4.identity();
    writeDelta(id, transform);
    return transform;
  }

  /// Hot-loop variant: all storage belongs to the resident animated instance.
  void writeDelta(String id, vm.Matrix4 transform) {
    final m = motions[id]!;
    if (m.kind == 'path') {
      _paths[id]!.writeTransform(
        (_phase[id] ?? 0) / m.periodSeconds + m.phaseOffset,
        transform,
        orient: m.orientToPath,
      );
      return;
    }
    final phase = (_phase[id] ?? 0) * 2 * math.pi / m.periodSeconds;
    transform.setIdentity();
    if (m.kind == 'bob') {
      final distance = (m.amplitude ?? 0) * math.sin(phase);
      transform.setTranslationRaw(
        m.axis == 'x' ? distance : 0,
        m.axis == 'y' ? distance : 0,
        m.axis == 'z' ? distance : 0,
      );
    } else {
      transform.setTranslationRaw(m.pivot[0], m.pivot[1], m.pivot[2]);
      switch (m.axis) {
        case 'x':
          transform.rotateX(phase);
        case 'y':
          transform.rotateY(phase);
        case 'z':
          transform.rotateZ(phase);
      }
      transform.translateByDouble(-m.pivot[0], -m.pivot[1], -m.pivot[2], 1);
    }
  }
}
