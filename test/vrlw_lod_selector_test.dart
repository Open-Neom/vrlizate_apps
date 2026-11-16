import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_apps/src/viewer/vrlw_lod_selector.dart';
import 'package:vrlizate_world/vrlizate_world.dart';

VrlwLodPolicy policy({VrlwLodBounds? bounds}) => VrlwLodPolicy(
  minDistancesMeters: const [0, 18, 42],
  bounds:
      bounds ??
      VrlwLodBounds(minX: -1, minY: 0, minZ: -1, maxX: 1, maxY: 2, maxZ: 1),
);

VrWorldEntity entity(
  String id, {
  String prototype = 'tree',
  VrWorldPosition? position,
  double scale = 1,
  double yaw = 0,
}) => VrWorldEntity(
  id: id,
  prototypeId: prototype,
  world: VrWorldAddress(worldId: 'test', instanceId: 'local'),
  transform: VrWorldTransform(
    position: position ?? VrWorldPosition.zero,
    scale: scale,
    yawRadians: yaw,
  ),
);

void main() {
  test('near/middle/far bands retain a visible last level', () {
    final bands = policy();
    expect(bands.levelAtDistance(0), 0);
    expect(bands.levelAtDistance(17.99), 0);
    expect(bands.levelAtDistance(18), 1);
    expect(bands.levelAtDistance(41.99), 1);
    expect(bands.levelAtDistance(42), 2);
    expect(bands.levelAtDistance(100000), 2);
  });

  test('hysteresis prevents oscillation near both transition distances', () {
    final bands = policy();
    var level = 0;
    for (final distance in [17.0, 18.1, 17.8, 19.9]) {
      level = bands.levelAtDistance(distance, previousLevel: level);
      expect(level, 0);
    }
    level = bands.levelAtDistance(20, previousLevel: level);
    expect(level, 1);
    for (final distance in [19.0, 18.0, 16.1, 43.9]) {
      level = bands.levelAtDistance(distance, previousLevel: level);
      expect(level, 1);
    }
    expect(bands.levelAtDistance(15.9, previousLevel: level), 0);
    level = bands.levelAtDistance(44, previousLevel: level);
    expect(level, 2);
    expect(bands.levelAtDistance(40.1, previousLevel: level), 2);
    expect(bands.levelAtDistance(39.9, previousLevel: level), 1);
    expect(bands.levelAtDistance(0, previousLevel: level), 0);
  });

  test('large objects use surface distance rather than distance to origin', () {
    final selector = VrlwLodSelector()
      ..register(
        'tree',
        policy(
          bounds: VrlwLodBounds(
            minX: 0,
            minY: 0,
            minZ: 0,
            maxX: 100,
            maxY: 20,
            maxZ: 10,
          ),
        ),
      );
    selector.replaceEntities([entity('a')]);
    selector.update(VrWorldPosition(99, 10, 5), 0);
    expect(selector.levelFor('a'), 0);
    selector.update(VrWorldPosition(143, 10, 5), 0, force: true);
    // 43 m from the surface, still within the far-transition hysteresis.
    expect(selector.levelFor('a'), 1);
    selector.update(VrWorldPosition(145, 10, 5), 0, force: true);
    expect(selector.levelFor('a'), 2);
  });

  test('distance transforms correctly through authored yaw and scale', () {
    final selector = VrlwLodSelector()
      ..register(
        'tree',
        policy(
          bounds: VrlwLodBounds(
            minX: 0,
            minY: 0,
            minZ: 0,
            maxX: 10,
            maxY: 2,
            maxZ: 2,
          ),
        ),
      );
    selector.replaceEntities([
      entity(
        'a',
        position: VrWorldPosition(100, 0, 100),
        scale: 2,
        yaw: math.pi / 2,
      ),
    ]);
    // The long axis now occupies z=80..100, not x=100..120.
    selector.update(VrWorldPosition(102, 1, 81), 0);
    expect(selector.levelFor('a'), 0);
    selector.update(VrWorldPosition(102, 1, 59), 0, force: true);
    expect(selector.levelFor('a'), 1);
    selector.update(VrWorldPosition(102, 1, 35), 0, force: true);
    expect(selector.levelFor('a'), 2);
    // Vertical separation also contributes, rather than projecting to XZ.
    selector.update(VrWorldPosition(102, 80, 90), 0, force: true);
    expect(selector.levelFor('a'), 2);
  });

  test('world distance thresholds are not divided by an instance scale', () {
    final selector = VrlwLodSelector()..register('tree', policy());
    selector.replaceEntities([entity('a', scale: 10)]);
    selector.update(VrWorldPosition(70, 10, 0), 0);
    expect(selector.levelFor('a'), 2); // 60 world m, not 6 local m.
    selector.update(VrWorldPosition(12, 10, 0), 0);
    expect(selector.levelFor('a'), 0);
  });

  test('tiny valid scales cannot overflow the distance calculation', () {
    final selector = VrlwLodSelector()..register('tree', policy());
    selector.replaceEntities([entity('a', scale: 1e-300)]);
    selector.update(VrWorldPosition(60, 1, 0), 0);
    expect(selector.levelFor('a'), 2);
    selector.update(VrWorldPosition.zero, 0);
    expect(selector.levelFor('a'), 0);
  });

  test(
    'stable frames and tiny tracker jitter do no per-entity distance work',
    () {
      final selector = VrlwLodSelector()..register('tree', policy());
      selector.replaceEntities([for (var i = 0; i < 100; i++) entity('e$i')]);
      selector.update(VrWorldPosition(5, 1, 0), 0);
      expect(selector.distanceEvaluations, 100);
      for (var i = 0; i < 120; i++) {
        selector.update(
          VrWorldPosition(5 + (i.isEven ? .1 : 0), 1, 0),
          1 / 120,
        );
      }
      expect(selector.distanceEvaluations, 100);
      expect(selector.update(VrWorldPosition(5.3, 1, 0), 1 / 120), isFalse);
      expect(selector.distanceEvaluations, 200); // Same band, no scene rebuild.
    },
  );

  test('normal movement is throttled but teleports select immediately', () {
    final selector = VrlwLodSelector()..register('tree', policy());
    selector.replaceEntities([entity('a')]);
    selector.update(VrWorldPosition(5, 1, 0), 0);
    selector.update(VrWorldPosition(5.5, 1, 0), .05);
    expect(selector.distanceEvaluations, 1);
    selector.update(VrWorldPosition(6, 1, 0), .06);
    expect(selector.distanceEvaluations, 2);
    expect(selector.update(VrWorldPosition(60, 1, 0), 0), isTrue);
    expect(selector.levelFor('a'), 2);
    expect(selector.update(VrWorldPosition(5, 1, 0), 0), isTrue);
    expect(selector.levelFor('a'), 0);
  });

  test(
    'residency refresh preserves hysteresis, evictions release identities',
    () {
      final selector = VrlwLodSelector()..register('tree', policy());
      final a = entity('a');
      selector.replaceEntities([a]);
      selector.update(
        VrWorldPosition(20, 1, 0),
        0,
      ); // 19 m => middle initially.
      expect(selector.levelFor('a'), 1);
      selector.replaceEntities([a]);
      expect(selector.update(VrWorldPosition(18, 1, 0), 0), isFalse);
      expect(selector.levelFor('a'), 1); // 17 m retained, not reset to near.
      selector.replaceEntities([]);
      expect(selector.trackedEntityCount, 0);
      expect(selector.levelFor('a'), 0);
      selector.replaceEntities([a]);
      selector.update(VrWorldPosition(18, 1, 0), 0);
      expect(
        selector.levelFor('a'),
        0,
      ); // New residency starts from exact distance.
    },
  );

  test('changed transforms keep IDs but update their spatial distance', () {
    final selector = VrlwLodSelector()..register('tree', policy());
    selector.replaceEntities([entity('a')]);
    selector.update(VrWorldPosition(60, 1, 0), 0);
    expect(selector.levelFor('a'), 2);
    selector.replaceEntities([
      entity('a', position: VrWorldPosition(60, 0, 0)),
    ]);
    expect(selector.update(VrWorldPosition(60, 1, 0), 0), isTrue);
    expect(selector.levelFor('a'), 0);
  });

  test('legacy and interactive prototypes do not enter the LOD scheduler', () {
    final selector = VrlwLodSelector();
    selector.replaceEntities([
      entity('legacy'),
      entity('vehicle', prototype: 'moving'),
    ]);
    expect(selector.update(VrWorldPosition(100, 1, 0), 1), isFalse);
    expect(selector.trackedEntityCount, 0);
    expect(selector.distanceEvaluations, 0);
    expect(selector.levelFor('legacy'), 0);
    expect(selector.levelFor('vehicle'), 0);
  });

  test(
    'changed prototype set isolates rebuilds and clears on stable updates',
    () {
      final selector = VrlwLodSelector()
        ..register('tree', policy())
        ..register('statue', policy());
      selector.replaceEntities([
        entity('tree1'),
        entity('tree2', position: VrWorldPosition(1, 0, 0)),
        entity(
          'statue',
          prototype: 'statue',
          position: VrWorldPosition(100, 0, 0),
        ),
        entity('vehicle', prototype: 'moving'),
      ]);
      selector.update(VrWorldPosition(5, 1, 0), 0);
      expect(selector.changedPrototypeIds, {'statue'});
      expect(selector.update(VrWorldPosition(23, 1, 0), 0), isTrue);
      expect(selector.changedPrototypeIds, {
        'tree',
      }); // Coalesces two instances.
      expect(
        () => selector.changedPrototypeIds.add('moving'),
        throwsUnsupportedError,
      );
      expect(selector.update(VrWorldPosition(23.01, 1, 0), 0), isFalse);
      expect(selector.changedPrototypeIds, isEmpty);
      expect(selector.update(VrWorldPosition(24, 1, 0), .2), isFalse);
      expect(selector.changedPrototypeIds, isEmpty);
      expect(selector.update(VrWorldPosition(100, 1, 0), 0), isTrue);
      expect(selector.changedPrototypeIds, {'tree', 'statue'});
      expect(selector.levelFor('vehicle'), 0);
      selector.clear();
      expect(selector.changedPrototypeIds, isEmpty);
    },
  );

  test(
    'clear releases policies, residents and all retained selection state',
    () {
      final selector = VrlwLodSelector()..register('tree', policy());
      selector.replaceEntities([entity('a')]);
      selector.update(VrWorldPosition(100, 1, 0), 1);
      selector.clear();
      expect(selector.distanceEvaluations, 0);
      expect(selector.trackedEntityCount, 0);
      expect(selector.levelFor('a'), 0);
      selector.replaceEntities([entity('a')]);
      selector.update(VrWorldPosition(100, 1, 0), 1);
      expect(selector.levelFor('a'), 0);
    },
  );

  test('refresh snapshots each band before a reentrant iterator update', () {
    final selector = VrlwLodSelector()..register('tree', policy());
    final a = entity('a'), b = entity('b');
    selector.replaceEntities([a, b]);
    selector.update(VrWorldPosition(25, 1, 0), 0);
    expect(selector.levelFor('a'), 1);
    expect(selector.levelFor('b'), 1);

    Iterable<VrWorldEntity> refresh() sync* {
      yield a;
      // Changes the old residents only. The first yielded band was already
      // captured; the next yielded band must reflect this update.
      selector.update(VrWorldPosition(5, 1, 0), 0, force: true);
      yield b;
    }

    selector.replaceEntities(refresh());
    expect(selector.levelFor('a'), 1);
    expect(selector.levelFor('b'), 0);
    expect(selector.trackedEntityCount, 2);
    expect(selector.distanceEvaluations, 4);
    expect(selector.changedPrototypeIds, {'tree'});
    expect(selector.update(VrWorldPosition(18, 1, 0), 0), isFalse);
    expect(selector.levelFor('a'), 1);
    expect(selector.levelFor('b'), 0);
    expect(selector.distanceEvaluations, 6);
  });

  test('nested replacement cannot mutate the outer band snapshot', () {
    final selector = VrlwLodSelector()..register('tree', policy());
    final a = entity('a'), b = entity('b');
    selector.replaceEntities([a, b]);
    selector.update(VrWorldPosition(25, 1, 0), 0);

    Iterable<VrWorldEntity> refresh() sync* {
      yield a;
      selector.replaceEntities([
        entity('a', position: VrWorldPosition(100, 0, 0)),
        b,
      ]);
      selector.update(VrWorldPosition(80, 1, 0), 0, force: true);
      yield b;
    }

    selector.replaceEntities(refresh());
    expect(selector.levelFor('a'), 1);
    expect(selector.levelFor('b'), 2);
    expect(selector.distanceEvaluations, 4);
    expect(selector.update(VrWorldPosition(5, 1, 0), 0), isTrue);
    expect(selector.levelFor('a'), 0);
    expect(selector.levelFor('b'), 0);
    expect(selector.changedPrototypeIds, {'tree'});
    expect(selector.distanceEvaluations, 6);
  });

  test('nested clear and registration retain each yielded policy snapshot', () {
    final selector = VrlwLodSelector()..register('tree', policy());
    final a = entity('a'), b = entity('b');
    selector.replaceEntities([a, b]);
    selector.update(VrWorldPosition(25, 1, 0), 0);

    Iterable<VrWorldEntity> refresh() sync* {
      yield a;
      selector.clear();
      selector.register(
        'tree',
        policy(
          bounds: VrlwLodBounds(
            minX: 0,
            minY: 0,
            minZ: -1,
            maxX: 10,
            maxY: 2,
            maxZ: 1,
          ),
        ),
      );
      yield b;
    }

    selector.replaceEntities(refresh());
    expect(selector.levelFor('a'), 1);
    expect(selector.levelFor('b'), 0);
    expect(selector.distanceEvaluations, 0);
    // a still measures its original one-meter bounds; b uses the new policy.
    expect(selector.update(VrWorldPosition(18, 1, 0), 0), isFalse);
    expect(selector.levelFor('a'), 1);
    expect(selector.levelFor('b'), 0);
    expect(selector.distanceEvaluations, 2);
  });

  test(
    'shared and fresh-equal transforms preserve geometry and changed yaw',
    () {
      final selector = VrlwLodSelector()
        ..register(
          'tree',
          policy(
            bounds: VrlwLodBounds(
              minX: 0,
              minY: 0,
              minZ: 0,
              maxX: 10,
              maxY: 2,
              maxZ: 2,
            ),
          ),
        );
      final original = entity(
        'a',
        position: VrWorldPosition(100, 0, 100),
        yaw: math.pi / 2,
        scale: 2,
      );
      final eye = VrWorldPosition(102, 1, 79);
      selector.replaceEntities([original]);
      selector.update(eye, 0);
      expect(selector.levelFor('a'), 0);

      final wrapper = original.copyWith();
      expect(identical(wrapper, original), isFalse);
      expect(identical(wrapper.transform, original.transform), isTrue);
      selector.replaceEntities([wrapper]);
      expect(selector.update(eye, 0), isFalse);
      expect(selector.levelFor('a'), 0);

      final equivalent = original.copyWith(
        transform: original.transform.copyWith(),
      );
      expect(identical(equivalent.transform, original.transform), isFalse);
      selector.replaceEntities([equivalent]);
      expect(selector.update(eye, 0), isFalse);
      expect(selector.levelFor('a'), 0);

      selector.replaceEntities([
        original.copyWith(
          transform: original.transform.copyWith(yawRadians: 0),
        ),
      ]);
      expect(selector.update(eye, 0), isTrue);
      expect(selector.levelFor('a'), 1); // Now 21 m from the unrotated surface.

      selector.replaceEntities([
        original.copyWith(
          transform: original.transform.copyWith(yawRadians: 0, scale: 10),
        ),
      ]);
      expect(selector.update(VrWorldPosition(180, 1, 100), 0), isTrue);
      expect(
        selector.levelFor('a'),
        0,
      ); // Inside the enlarged, unrotated bounds.
      expect(selector.distanceEvaluations, 5);
    },
  );

  test('shared policy changes prototype without losing its band snapshot', () {
    final shared = policy();
    final selector = VrlwLodSelector()
      ..register('tree', shared)
      ..register('statue', shared);
    final original = entity('a');
    selector.replaceEntities([original]);
    selector.update(VrWorldPosition(25, 1, 0), 0);
    selector.replaceEntities([
      VrWorldEntity(
        id: 'a',
        prototypeId: 'statue',
        world: original.world,
        transform: original.transform,
      ),
    ]);
    expect(selector.levelFor('a'), 1);
    expect(selector.update(VrWorldPosition(18, 1, 0), 0), isFalse);
    expect(selector.levelFor('a'), 1);
    expect(selector.changedPrototypeIds, isEmpty);
    expect(selector.update(VrWorldPosition(5, 1, 0), 0), isTrue);
    expect(selector.changedPrototypeIds, {'statue'});
  });

  test(
    'invalid policies and distances cannot cause ambiguous band selection',
    () {
      final bounds = policy().bounds;
      for (final distances in <List<double>>[
        [],
        [0],
        [1, 18],
        [0, 18, 18],
        [0, 3],
        [0, double.infinity],
      ]) {
        expect(
          () => VrlwLodPolicy(minDistancesMeters: distances, bounds: bounds),
          throwsArgumentError,
        );
      }
      expect(() => policy().levelAtDistance(double.nan), throwsArgumentError);
      expect(() => policy().levelAtDistance(-1), throwsArgumentError);
      expect(
        () => policy().levelAtDistance(1, previousLevel: 3),
        throwsArgumentError,
      );
      expect(
        () =>
            VrlwLodBounds(minX: 1, minY: 0, minZ: 0, maxX: 0, maxY: 1, maxZ: 1),
        throwsArgumentError,
      );
    },
  );
}
