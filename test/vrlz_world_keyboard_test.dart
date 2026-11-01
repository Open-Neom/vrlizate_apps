import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;
import 'package:vrlizate_apps/src/viewer/vrlz_world_keyboard.dart';
import 'package:vrlizate_scene/vrlizate_scene.dart' show StereoHeadRig;

void main() {
  test(
    'idle and opposing keys do not read camera bases or change position',
    () {
      final rig = _CountingRig()..eyeCenter.setValues(2, 1.6, -4);
      for (final keys in <Set<LogicalKeyboardKey>>[
        {},
        {LogicalKeyboardKey.space},
        {LogicalKeyboardKey.keyW, LogicalKeyboardKey.keyS},
        {LogicalKeyboardKey.keyA, LogicalKeyboardKey.keyD},
        {
          LogicalKeyboardKey.keyW,
          LogicalKeyboardKey.keyS,
          LogicalKeyboardKey.keyA,
          LogicalKeyboardKey.keyD,
        },
      ]) {
        for (var frame = 0; frame < 120; frame++) {
          applyVrlzKeyboardMotion(rig, keys, 1 / 120);
        }
      }
      expect(rig.forwardReads, 0);
      expect(rig.rightReads, 0);
      expect(rig.eyeCenter, vm.Vector3(2, 1.6, -4));
    },
  );

  test('arrow-only look preserves clamped step without camera basis reads', () {
    final rig = _CountingRig();
    applyVrlzKeyboardMotion(rig, {
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowUp,
    }, 1);
    expect(rig.bodyYaw, .05);
    expect(rig.bodyPitch, -.05);
    applyVrlzKeyboardMotion(rig, {
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowDown,
    }, .02);
    expect(rig.bodyYaw, closeTo(.03, 1e-12));
    expect(rig.bodyPitch, closeTo(-.03, 1e-12));
    expect(rig.forwardReads, 0);
    expect(rig.rightReads, 0);
    expect(rig.eyeCenter, vm.Vector3.zero());
  });

  test(
    'WASD retains planar speed, diagonal normalization and body heading',
    () {
      for (final yaw in [0.0, .7, -2.0]) {
        for (final axes in [(0, 1), (0, -1), (1, 0), (-1, 0), (1, 1)]) {
          final rig = StereoHeadRig(eyeCenter: vm.Vector3(2, 1.6, -4))
            ..setOrientation(.3, .7)
            ..bodyYaw = yaw;
          final origin = rig.eyeCenter.clone();
          final expected = vm.Vector3.zero();
          if (axes.$2 != 0) {
            final forward = rig.forward..y = 0;
            expected.add(forward.normalized() * axes.$2.toDouble());
          }
          if (axes.$1 != 0) {
            final right = rig.screenRight..y = 0;
            expected.add(right.normalized() * axes.$1.toDouble());
          }
          expected.normalize();
          applyVrlzKeyboardMotion(rig, {
            if (axes.$2 > 0) LogicalKeyboardKey.keyW,
            if (axes.$2 < 0) LogicalKeyboardKey.keyS,
            if (axes.$1 > 0) LogicalKeyboardKey.keyD,
            if (axes.$1 < 0) LogicalKeyboardKey.keyA,
          }, .02);
          final displacement = rig.eyeCenter - origin;
          // The rig stores its pose with float32 precision.
          expect(displacement.length, closeTo(.05, 1e-6));
          expect(
            displacement.normalized().distanceTo(expected),
            lessThan(1e-5),
          );
          expect(rig.eyeCenter.y, closeTo(1.6, 1e-6));
        }
      }
    },
  );

  test('opposing WASD still allows arrow rotation', () {
    final rig = _CountingRig();
    applyVrlzKeyboardMotion(rig, {
      LogicalKeyboardKey.keyW,
      LogicalKeyboardKey.keyS,
      LogicalKeyboardKey.arrowRight,
    }, .01);
    expect(rig.bodyYaw, -.01);
    expect(rig.forwardReads, 0);
    expect(rig.rightReads, 0);
  });
}

class _CountingRig extends StereoHeadRig {
  int forwardReads = 0, rightReads = 0;

  @override
  vm.Vector3 get forward {
    forwardReads++;
    return super.forward;
  }

  @override
  vm.Vector3 get screenRight {
    rightReads++;
    return super.screenRight;
  }
}
