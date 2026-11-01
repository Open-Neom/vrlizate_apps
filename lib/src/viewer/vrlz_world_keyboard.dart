import 'dart:math' as math;

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:vrlizate_scene/vrlizate_scene.dart' show StereoHeadRig;

/// Creator keyboard fallback only. The caller excludes keys while a VR input
/// arbiter or the passport owns controls; joystick motion stays in the SDK.
void applyVrlzKeyboardMotion(
  StereoHeadRig rig,
  Set<LogicalKeyboardKey> keys,
  double dt,
) {
  if (keys.isEmpty) return;
  final step = dt.clamp(0.0, .05);
  var x = 0.0, z = 0.0;
  if (keys.contains(LogicalKeyboardKey.keyW)) z++;
  if (keys.contains(LogicalKeyboardKey.keyS)) z--;
  if (keys.contains(LogicalKeyboardKey.keyD)) x++;
  if (keys.contains(LogicalKeyboardKey.keyA)) x--;
  // Camera basis getters allocate vectors (and compose head/body orientation).
  // Neither idle mobile frames nor cancelling WASD keys need that work.
  if (x != 0 || z != 0) {
    final forward = rig.forward..y = 0;
    if (forward.length2 > .001) forward.normalize();
    final right = rig.screenRight..y = 0;
    if (right.length2 > .001) right.normalize();
    final norm = math.max(1.0, math.sqrt(x * x + z * z));
    rig.eyeCenter.add((forward * z + right * x) * (2.5 * step / norm));
  }
  if (keys.contains(LogicalKeyboardKey.arrowLeft)) rig.bodyYaw += step;
  if (keys.contains(LogicalKeyboardKey.arrowRight)) rig.bodyYaw -= step;
  if (keys.contains(LogicalKeyboardKey.arrowUp)) rig.bodyPitch -= step;
  if (keys.contains(LogicalKeyboardKey.arrowDown)) rig.bodyPitch += step;
}
