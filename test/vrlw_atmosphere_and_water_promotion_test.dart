import 'package:flutter_scene/scene.dart' as fs;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;
import 'package:vrlizate_apps/src/viewer/vrlw_day_night.dart';
import 'package:vrlizate_scene/vrlizate_scene.dart';
import 'package:vrlizate_world/vrlizate_world.dart';

void main() {
  test('VRLW atmosphere promotion combines day-night cycle with height-fog and water detection', () {
    const env = VrlwEnvironmentSpec(
      sunDirection: [0.3, -0.9, -0.4],
      sunIntensity: 2.4,
      dayNightCycle: VrlwDayNightCycleSpec(
        durationSeconds: 360,
        initialHour: 17.5,
      ),
      fogDensity: 0.008,
      fogMaxOpacity: 0.78,
      fogHeightFalloff: 0.05,
      fogCutoffDistance: 330,
      fogSkyColorInfluence: 0.28,
      fogSunInScatter: 0.24,
      animatedWater: true,
    );

    final fog = fs.Fog();
    final biomeFallback = VrAtmosphericFogProfile.forWorldId('selma_sanctuary');
    final profile = VrAtmosphericFogProfile(
      enabled: (env.fogDensity ?? biomeFallback.density) > 0,
      color: env.fogColor != null
          ? vm.Vector3.array(env.fogColor!)
          : biomeFallback.color,
      density: env.fogDensity ?? biomeFallback.density,
      maxOpacity: env.fogMaxOpacity ?? biomeFallback.maxOpacity,
      heightFalloff: env.fogHeightFalloff ?? biomeFallback.heightFalloff,
      cutoffDistance: env.fogCutoffDistance ?? biomeFallback.cutoffDistance,
      skyColorInfluence:
          env.fogSkyColorInfluence ?? biomeFallback.skyColorInfluence,
      sunInScatter: env.fogSunInScatter ?? biomeFallback.sunInScatter,
    );
    profile.applyToFog(fog);

    expect(fog.enabled, isTrue);
    expect(fog.density, closeTo(0.008, 1e-6));
    expect(fog.heightFalloff, closeTo(0.05, 1e-6));

    final dayNight = VrlwDayNightLighting(env.dayNightCycle!);
    dayNight.sample(0);
    VrAtmosphericFogProfile.syncDynamicHorizonFog(
      fog,
      horizonColor: dayNight.horizonColor,
      sunAltitude: dayNight.sunDirection.y,
      baseSunInScatter: profile.sunInScatter,
    );
    expect(fog.color.x, closeTo(dayNight.horizonColor.x, 1e-5));
    expect(fog.sunInScatter, greaterThan(0.05));

    // Verify water surface promotion matches lakes/rivers/pools cleanly.
    expect(
      VrWaterSurfaceClassifier.isWaterSurface(
        prototypeId: 'sacred_valley_lake',
      ),
      isTrue,
    );
    expect(
      VrWaterSurfaceClassifier.isWaterSurface(prototypeId: 'citadel_wall'),
      isFalse,
    );
  });
}
