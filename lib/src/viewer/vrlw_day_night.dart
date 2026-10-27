import 'dart:math' as math;

import 'package:flutter_scene/kit.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;
import 'package:vrlizate_world/vrlizate_world.dart';

/// Lighting samples driven only by a world's active time, at the adapter's 5Hz.
/// Reuses Scene's atmospheric evaluator without attaching its per-frame clock.
/// No real clock, dynamic environment bake or extra shadow passes.
final class VrlwDayNightLighting {
  VrlwDayNightLighting(
    this.spec, {
    this.baseSunIntensity = 2.5,
    this.baseEnvironmentIntensity = 1,
    this.baseExposure = 1,
  }) {
    sample(0);
  }

  final VrlwDayNightCycleSpec spec;
  final double baseSunIntensity, baseEnvironmentIntensity, baseExposure;
  final _cycle = fs.DayNightCycleComponent(latitude: 24);
  final sunDirection = vm.Vector3.zero();
  final lightDirection = vm.Vector3.zero();
  final lightColor = vm.Vector3.zero();
  final sunColor = vm.Vector3.zero();
  final zenithColor = vm.Vector3.zero();
  final horizonColor = vm.Vector3.zero();
  final groundColor = vm.Vector3.zero();
  double hour = 12, sunIntensity = 2.5, environmentIntensity = 1, exposure = 1;

  void sample(double activeSeconds) {
    final seconds = activeSeconds.isFinite && activeSeconds > 0
        ? activeSeconds
        : 0.0;
    hour =
        (spec.initialHour +
            (seconds % spec.durationSeconds) * 24 / spec.durationSeconds) %
        24;
    _cycle.timeOfDay = hour;
    sunDirection.setFrom(_cycle.sunDirection);
    final atmosphere = _cycle.evaluateLighting();
    final altitude = sunDirection.y;
    final day = _smooth(-.15, .35, altitude);
    final twilight = (1 - _smooth(0, .45, altitude.abs())) * day;
    // At night the weak cool directional fill stays above the horizon; the
    // visible sun continues below it. Diffuse IBL keeps the ground readable.
    lightDirection.setValues(
      -sunDirection.x,
      -math.max(.22, altitude.abs()),
      -sunDirection.z,
    );
    lightDirection.normalize();
    lightColor.setFrom(atmosphere.sunColor);
    sunIntensity =
        baseSunIntensity * (.025 + .975 * atmosphere.sunIntensity / 3);
    environmentIntensity =
        baseEnvironmentIntensity *
        (.3 + .7 * atmosphere.environmentIntensity / .8);
    exposure = baseExposure * (1.12 - .12 * day);
    sunColor.setValues(
      lightColor.x * day * 3,
      lightColor.y * day * 3,
      lightColor.z * day * 3,
    );
    zenithColor.setValues(
      .008 + .052 * day + .055 * twilight,
      .014 + .21 * day - .075 * twilight,
      .04 + .48 * day - .22 * twilight,
    );
    horizonColor.setValues(
      .022 + .53 * day + .20 * twilight,
      .03 + .65 * day - .25 * twilight,
      .07 + .72 * day - .43 * twilight,
    );
    groundColor.setValues(
      .025 + .115 * day,
      .03 + .115 * day,
      .045 + .105 * day,
    );
  }

  static double _smooth(double a, double b, double value) {
    final t = ((value - a) / (b - a)).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }
}
