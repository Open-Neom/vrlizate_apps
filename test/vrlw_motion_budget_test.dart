import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_apps/src/viewer/vrlw_scene_adapter.dart';
import 'package:vrlizate_world/vrlizate_world.dart';

VrWorldEntity _entity(int n, {String prototype = 'rotor', double x = 0}) =>
    VrWorldEntity(
      id: 'resident-$n',
      prototypeId: prototype,
      world: VrWorldAddress(worldId: 'test.world', instanceId: 'local'),
      transform: VrWorldTransform(position: VrWorldPosition(x, 0, 0)),
    );

void main() {
  test(
    'sixteen resident moving primitives fit; the next instance is rejected',
    () {
      final residents = List.generate(16, _entity);
      expect(
        () => VrlwSceneAdapter.validateActiveMotion(residents, {'rotor': 1}),
        returnsNormally,
      );
      expect(
        () => VrlwSceneAdapter.validateActiveMotion(
          [...residents, _entity(16)],
          {'rotor': 1},
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'a multi-material animated mesh charges each moving primitive per entity',
    () {
      final residents = List.generate(8, _entity);
      expect(
        () => VrlwSceneAdapter.validateActiveMotion(residents, {'rotor': 2}),
        returnsNormally,
      );
      expect(
        () => VrlwSceneAdapter.validateActiveMotion(
          [...residents, _entity(8)],
          {'rotor': 2},
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'static parts do not consume motion slots but retain geometry accounting',
    () {
      final residents = [
        ...List.generate(8, _entity),
        for (var i = 8; i < 108; i++) _entity(i, prototype: 'bench'),
      ];
      // Each rotor has two moving groups and three stationary housing groups;
      // stationary benches coexist without consuming the sixteen animation slots.
      expect(
        () => VrlwSceneAdapter.validateActiveMotion(residents, {
          'rotor': 2,
          'bench': 0,
        }),
        returnsNormally,
      );
      expect(
        () => VrlwSceneAdapter.validateActiveGeometry(residents, {
          'rotor': [100, 100, 100, 100, 100],
          'bench': [100],
        }),
        returnsNormally,
      );
      expect(
        () => VrlwSceneAdapter.validateActiveGeometry(residents, {
          'rotor': [4000, 4000, 4000, 4000, 4000],
          'bench': [100],
        }),
        throwsFormatException,
      );
    },
  );

  test('independent prototypes share one resident animation budget', () {
    final residents = [
      for (var i = 0; i < 5; i++) _entity(i, prototype: 'fan'),
      for (var i = 5; i < 8; i++) _entity(i, prototype: 'bell'),
    ];
    expect(
      () => VrlwSceneAdapter.validateActiveMotion(residents, {
        'fan': 2,
        'bell': 2,
      }),
      returnsNormally,
    );
    expect(
      () => VrlwSceneAdapter.validateActiveMotion(
        [...residents, _entity(8, prototype: 'sign')],
        {'fan': 2, 'bell': 2, 'sign': 1},
      ),
      throwsFormatException,
    );
  });

  test(
    'distance culling cannot bypass the resident animation allocation cap',
    () {
      final residents = [
        for (var i = 0; i < 17; i++) _entity(i, x: 1000000 + i.toDouble()),
      ];
      expect(
        () => VrlwSceneAdapter.validateActiveMotion(residents, {'rotor': 1}),
        throwsFormatException,
      );
    },
  );

  test(
    'unknown and negative prototype accounting fail before changing instances',
    () {
      expect(
        () => VrlwSceneAdapter.validateActiveMotion([_entity(0)], {}),
        throwsFormatException,
      );
      expect(
        () =>
            VrlwSceneAdapter.validateActiveMotion([_entity(0)], {'rotor': -1}),
        throwsFormatException,
      );
      expect(
        () => VrlwSceneAdapter.validateActiveMotion([_entity(0)], {'rotor': 0}),
        returnsNormally,
      );
    },
  );

  test('clearing a world releases its full independent motion budget', () {
    expect(
      () => VrlwSceneAdapter.validateActiveMotion(List.generate(16, _entity), {
        'rotor': 1,
      }),
      returnsNormally,
    );
    expect(
      () => VrlwSceneAdapter.validateActiveMotion([], {}),
      returnsNormally,
    );
    expect(
      () => VrlwSceneAdapter.validateActiveMotion(
        [_entity(99, prototype: 'observatory')],
        {'observatory': 16},
      ),
      returnsNormally,
    );
  });
}
