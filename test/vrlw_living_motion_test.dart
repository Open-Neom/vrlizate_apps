import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;
import 'package:vrlizate_apps/src/viewer/vrlw_day_night.dart';
import 'package:vrlizate_apps/src/viewer/vrlw_path_sampler.dart';
import 'package:vrlizate_apps/src/viewer/vrlw_world_activity.dart';
import 'package:vrlizate_apps/vrlizate_apps.dart';
import 'package:vrlizate_world/vrlizate_world.dart';

import 'support/vrlz_world_fixture.dart';
import 'support/vrz_fixture.dart';

const _route = <List<double>>[
  [0, 0, 0],
  [12, 0, 0],
  [12, 0, 6],
  [0, 0, 6],
];

VrlwWorldActivity _activity({double phase = 0, bool orient = true}) =>
    VrlwWorldActivity(
      VrlwBundleIndex(
        header: VrlwBundleHeader(2, 0),
        id: 'routes',
        title: 'Routes',
        revision: '1.0.0-beta.1',
        license: 'MIT',
        gridId: 'local',
        cellSizeMeters: 32,
        prototypeIds: {'walker'},
        origin: {'type': 'local'},
        indexSha256: '0' * 64,
        chunks: [],
        resources: [],
        prototypeBindings: [],
        environment: const VrlwEnvironmentSpec(
          dayNightCycle: VrlwDayNightCycleSpec(
            durationSeconds: 120,
            initialHour: 6,
          ),
        ),
        motions: [
          VrlwMotionSpec(
            id: 'walking',
            prototypeId: 'walker',
            node: 'body',
            kind: 'path',
            axis: 'y',
            periodSeconds: 4,
            waypoints: _route,
            phaseOffset: phase,
            orientToPath: orient,
          ),
        ],
        interactions: [
          VrlwInteractionSpec(
            id: 'pause',
            label: 'Pausa',
            position: [0, 1.6, 0],
            action: 'toggleMotion',
            target: 'walking',
          ),
        ],
      ),
    );

void _matrixNear(vm.Matrix4 a, vm.Matrix4 b, [double tolerance = 1e-9]) {
  for (var i = 0; i < 16; i++) {
    expect(a.storage[i], closeTo(b.storage[i], tolerance), reason: 'matrix $i');
  }
}

void main() {
  test('closed route has matching position and heading across the seam', () {
    final path = VrlwPathSampler(_route);
    final first = vm.Matrix4.identity(), next = vm.Matrix4.identity();
    path.writeTransform(0, first);
    path.writeTransform(1, next);
    _matrixNear(first, next);
    path.writeTransform(-.000001, first);
    path.writeTransform(.000001, next);
    expect(
      first.getTranslation().distanceTo(next.getTranslation()),
      lessThan(.001),
    );
    final a = first.transform3(vm.Vector3(0, 0, -1)) - first.getTranslation();
    final b = next.transform3(vm.Vector3(0, 0, -1)) - next.getTranslation();
    expect(a.dot(b), greaterThan(.999));
  });

  for (final phase in [-1e-20, -double.minPositive]) {
    test('negative tiny phase $phase wraps without extrapolation', () {
      final path = VrlwPathSampler(_route);
      final seam = vm.Matrix4.identity(), wrapped = vm.Matrix4.identity();
      path.writeTransform(0, seam);
      path.writeTransform(phase, wrapped);
      _matrixNear(wrapped, seam);
      expect(
        wrapped.getTranslation().distanceTo(path.boundsCenter),
        lessThanOrEqualTo(path.boundsRadius + 1e-9),
      );
      expect(wrapped.storage.every((value) => value.isFinite), isTrue);
    });
  }

  test('uneven waypoint spacing advances with stable arc-length speed', () {
    final path = VrlwPathSampler(_route), transform = vm.Matrix4.identity();
    path.writeTransform(0, transform, orient: false);
    var previous = transform.getTranslation();
    var minStep = double.infinity, maxStep = 0.0;
    for (var i = 1; i <= 1024; i++) {
      path.writeTransform(i / 1024, transform, orient: false);
      final current = transform.getTranslation();
      final distance = current.distanceTo(previous);
      minStep = math.min(minStep, distance);
      maxStep = math.max(maxStep, distance);
      previous = current;
    }
    expect(minStep, greaterThan(0));
    expect(maxStep / minStep, lessThan(1.04));
  });

  test('model forward minus Z follows the horizontal route tangent', () {
    final path = VrlwPathSampler(_route);
    final pose = vm.Matrix4.identity(), before = vm.Matrix4.identity();
    final after = vm.Matrix4.identity();
    for (var i = 0; i < 100; i++) {
      final phase = i / 100;
      path.writeTransform(phase, pose);
      path.writeTransform(phase - .0001, before);
      path.writeTransform(phase + .0001, after);
      final direction = after.getTranslation() - before.getTranslation();
      direction.normalize();
      final forward =
          pose.transform3(vm.Vector3(0, 0, -1)) - pose.getTranslation();
      expect(forward.dot(direction), greaterThan(.995));
      expect(forward.y, 0);
    }
  });

  test(
    'orientation opt-out preserves the authored heading while translating',
    () {
      final path = VrlwPathSampler(_route), matrix = vm.Matrix4.identity();
      path.writeTransform(.37, matrix, orient: false);
      expect(matrix.getTranslation().length, greaterThan(1));
      matrix.setTranslationRaw(0, 0, 0);
      _matrixNear(matrix, vm.Matrix4.identity());
    },
  );

  test(
    'activation envelope contains the entire curved route including overshoot',
    () {
      final path = VrlwPathSampler(_route), matrix = vm.Matrix4.identity();
      var overshot = false;
      for (var i = 0; i < 4096; i++) {
        path.writeTransform(i / 4096, matrix);
        final point = matrix.getTranslation();
        overshot |= point.x < 0 || point.x > 12 || point.z < 0 || point.z > 6;
        expect(
          point.distanceTo(path.boundsCenter),
          lessThanOrEqualTo(path.boundsRadius + 1e-9),
        );
      }
      expect(overshot, isTrue);
      expect(path.boundsRadius, greaterThan(0));
    },
  );

  test('very small valid routes do not underflow arc-length normalization', () {
    final path = VrlwPathSampler([
      [0, 0, 0],
      [1e-200, 0, 0],
      [0, 0, 1e-200],
    ]);
    expect(path.length, greaterThan(0));
    final matrix = vm.Matrix4.identity();
    for (var i = 0; i < 20; i++) {
      path.writeTransform(i / 20, matrix);
      expect(matrix.storage.every((v) => v.isFinite), isTrue);
    }
  });

  test('sampler rejects malformed routes and handles invalid sample phase', () {
    for (final points in <List<List<double>>>[
      [
        [0, 0, 0],
        [1, 0, 0],
      ],
      [
        [0, 0, 0],
        [1, 0, 0],
        [0, 0, 0],
      ],
      [
        [0, 0, 0],
        [33, 0, 0],
        [0, 0, 1],
      ],
      [
        [0, 0, 0],
        [double.nan, 0, 0],
        [0, 0, 1],
      ],
    ]) {
      expect(() => VrlwPathSampler(points), throwsFormatException);
    }
    final path = VrlwPathSampler(_route), first = vm.Matrix4.identity();
    final invalid = vm.Matrix4.identity();
    path.writeTransform(0, first);
    path.writeTransform(double.infinity, invalid);
    _matrixNear(first, invalid);
  });

  test(
    'phase offset and caller-owned matrix agree with retained activity pose',
    () {
      final activity = _activity(phase: .25);
      final expected = vm.Matrix4.identity(), actual = vm.Matrix4.identity();
      VrlwPathSampler(_route).writeTransform(.25, expected);
      activity.writeDelta('walking', actual);
      _matrixNear(actual, expected);
      for (var i = 0; i < 10; i++) {
        activity.advance(.1, {'walking'});
      }
      VrlwPathSampler(_route).writeTransform(.5, expected);
      activity.writeDelta('walking', actual);
      _matrixNear(actual, expected);
    },
  );

  test(
    'pause, distant residency and re-entry preserve path phase and local time',
    () {
      final activity = _activity();
      for (var i = 0; i < 10; i++) {
        activity.advance(.1, {'walking'});
      }
      final pose = activity.delta('walking');
      for (var i = 0; i < 100; i++) {
        activity.advance(.1, {'walking'}, active: false);
      }
      expect(activity.activeSeconds, closeTo(1, 1e-9));
      _matrixNear(activity.delta('walking'), pose);
      for (var i = 0; i < 10; i++) {
        activity.advance(.1, {});
      }
      expect(activity.activeSeconds, closeTo(2, 1e-9));
      _matrixNear(activity.delta('walking'), pose);
      final retained = activity;
      retained.advance(.1, {'walking'});
      final expected = _activity();
      for (var i = 0; i < 11; i++) {
        expected.advance(.1, {'walking'});
      }
      _matrixNear(retained.delta('walking'), expected.delta('walking'));
    },
  );

  test('motion toggle freezes path without stopping day/night time', () {
    final activity = _activity();
    activity.advance(.1, {'walking'});
    final pose = activity.delta('walking');
    activity.activate('pause', vm.Vector3(0, 1.6, 0));
    for (var i = 0; i < 8; i++) {
      activity.advance(.1, {'walking'});
    }
    _matrixNear(activity.delta('walking'), pose);
    expect(activity.activeSeconds, closeTo(.9, 1e-9));
    activity.activate('pause', vm.Vector3(0, 1.6, 0));
    activity.advance(.1, {'walking'});
    expect(
      activity
          .delta('walking')
          .getTranslation()
          .distanceTo(pose.getTranslation()),
      greaterThan(.1),
    );
  });

  test(
    'invalid dt cannot change paths or day/night state; long gaps clamp',
    () {
      final activity = _activity(), pose = _activity().delta('walking');
      for (final dt in [0.0, -1.0, double.nan, double.infinity]) {
        activity.advance(dt, {'walking'});
        _matrixNear(activity.delta('walking'), pose);
        expect(activity.activeSeconds, 0);
      }
      activity.advance(120, {'walking'});
      expect(activity.activeSeconds, .1);
    },
  );

  test('day/night wraps continuously at midnight, dawn and dusk', () {
    const spec = VrlwDayNightCycleSpec(durationSeconds: 240, initialHour: 0);
    final a = VrlwDayNightLighting(spec), b = VrlwDayNightLighting(spec);
    for (final seconds in [0.0, 60.0, 120.0, 180.0, 240.0]) {
      a.sample((seconds - .00001 + 240) % 240);
      b.sample((seconds + .00001) % 240);
      expect(a.sunDirection.distanceTo(b.sunDirection), lessThan(.00001));
      expect(a.lightColor.distanceTo(b.lightColor), lessThan(.00001));
      expect(a.horizonColor.distanceTo(b.horizonColor), lessThan(.00001));
      expect(a.sunIntensity, closeTo(b.sunIntensity, .00001));
      expect(a.environmentIntensity, closeTo(b.environmentIntensity, .00001));
      expect(a.exposure, closeTo(b.exposure, .00001));
    }
    a.sample(0);
    b.sample(240);
    expect(a.hour, 0);
    expect(b.hour, 0);
    expect(a.sunDirection, b.sunDirection);
  });

  test(
    'night stays legible and daylight changes without touching materials',
    () {
      final sample = VrlwDayNightLighting(
        const VrlwDayNightCycleSpec(durationSeconds: 240, initialHour: 0),
      );
      final nightIntensity = sample.sunIntensity;
      final nightAmbient = sample.environmentIntensity;
      final nightExposure = sample.exposure;
      expect(nightIntensity, greaterThan(0));
      expect(nightAmbient, greaterThan(.3));
      expect(sample.horizonColor.length, greaterThan(.05));
      sample.sample(120);
      expect(sample.hour, 12);
      expect(sample.sunIntensity, greaterThan(nightIntensity));
      expect(sample.environmentIntensity, greaterThan(nightAmbient));
      expect(sample.exposure, lessThan(nightExposure));
      for (final seconds in [double.nan, double.infinity, -1.0]) {
        sample.sample(seconds);
        expect(sample.hour, 0);
        expect(sample.sunDirection.storage.every((v) => v.isFinite), isTrue);
      }
    },
  );

  test(
    'portable profile prepares named path and day/night before GPU import',
    () async {
      final model = triangleGlb(
        changeJson: (json) => json['nodes'][0]['name'] = 'body',
      );
      final fixture = worldFixture(
        model: model,
        changeWorld: (world) {
          world['motions'] = [
            {
              'id': 'walking',
              'prototypeId': 'test.floor',
              'node': 'body',
              'kind': 'path',
              'axis': 'y',
              'periodSeconds': 4,
              'waypoints': _route,
              'phaseOffset': .25,
            },
          ];
          world['environment'] = {
            'dayNightCycle': {'durationSeconds': 240, 'initialHour': 6},
          };
        },
      );
      final bundle = VrlzWorldBundle.decode(
        VrlzWorldBundle.encode(fixture.manifest, fixture.files),
      );
      final prepared = await bundle.openWorld('garden');
      try {
        final index = prepared.reader.index;
        expect(index.motions.single.kind, 'path');
        expect(index.environment!.dayNightCycle!.initialHour, 6);
        final activity = VrlwWorldActivity(index);
        expect(
          activity.delta('walking').getTranslation().length,
          greaterThan(1),
        );
      } finally {
        await prepared.reader.close();
      }
    },
  );

  test(
    'path targeting transformed mesh is rejected before GPU import',
    () async {
      final model = triangleGlb(
        changeJson: (json) {
          json['nodes'][0]['name'] = 'body';
          json['nodes'][0]['translation'] = [1, 0, 0];
        },
      );
      final fixture = worldFixture(
        model: model,
        changeWorld: (world) {
          world['motions'] = [
            {
              'id': 'walking',
              'prototypeId': 'test.floor',
              'node': 'body',
              'kind': 'path',
              'axis': 'y',
              'periodSeconds': 4,
              'waypoints': _route,
            },
          ];
        },
      );
      final bundle = VrlzWorldBundle.decode(
        VrlzWorldBundle.encode(fixture.manifest, fixture.files),
      );
      await expectLater(bundle.openWorld('garden'), throwsFormatException);
    },
  );
}
