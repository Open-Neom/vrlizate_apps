import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_apps/src/viewer/vrlw_scene_adapter.dart';
import 'package:vrlizate_world/vrlizate_world.dart';

VrWorldEntity entity(int number, {String prototype = 'sculpture'}) =>
    VrWorldEntity(
      id: 'entity.$number',
      prototypeId: prototype,
      world: VrWorldAddress(worldId: 'test.world', instanceId: 'local'),
      transform: VrWorldTransform(
        position: VrWorldPosition(number.toDouble(), 0, 0),
      ),
    );

Matcher failureWith(String text) => throwsA(
  isA<FormatException>().having(
    (error) => error.message,
    'message',
    contains(text),
  ),
);

void main() {
  test('shared high-detail mesh is charged for every resident instance', () {
    final entities = List.generate(4, entity);
    const models = {
      'sculpture': [12000, 8000],
    };
    // Four instances of an accepted 20k model fill the scene's 80k budget.
    expect(
      () => VrlwSceneAdapter.validateActiveGeometry(entities, models),
      returnsNormally,
    );
    // This still has only five entities and ten primitives: the triangle
    // budget must reject it even though the previous two limits allow it.
    expect(
      () => VrlwSceneAdapter.validateActiveGeometry([
        ...entities,
        entity(4),
      ], models),
      failureWith('80000 resident instanced triangles'),
    );
  });

  test('multiple prototypes share the same resident triangle budget', () {
    expect(
      () => VrlwSceneAdapter.validateActiveGeometry(
        [for (var i = 0; i < 4; i++) entity(i), entity(4, prototype: 'floor')],
        const {
          'sculpture': [20000],
          'floor': [2],
        },
      ),
      failureWith('80000 resident instanced triangles'),
    );
    // Clearing the prior world/resident set allows the next world to use
    // its entire independent budget; accounting never accumulates over time.
    expect(
      () => VrlwSceneAdapter.validateActiveGeometry(
        [entity(4, prototype: 'floor')],
        const {
          'floor': [2],
        },
      ),
      returnsNormally,
    );
  });

  test('cheap meshes still honor entity and primitive instance budgets', () {
    final entities = List.generate(128, entity);
    expect(
      () => VrlwSceneAdapter.validateActiveGeometry(entities, const {
        'sculpture': [1, 1],
      }),
      returnsNormally,
    );
    expect(
      () => VrlwSceneAdapter.validateActiveGeometry(
        [...entities, entity(128)],
        const {
          'sculpture': [1],
        },
      ),
      failureWith('128 resident entities'),
    );
    expect(
      () => VrlwSceneAdapter.validateActiveGeometry(entities, const {
        'sculpture': [1, 1, 1],
      }),
      failureWith('256 resident primitive instances'),
    );
  });

  test('invalid geometry and duplicate entity IDs cannot undercount work', () {
    expect(
      () => VrlwSceneAdapter.validateActiveGeometry(
        [entity(0), entity(0)],
        const {
          'sculpture': [1],
        },
      ),
      failureWith('Duplicate resident entity ID'),
    );
    expect(
      () => VrlwSceneAdapter.validateActiveGeometry([entity(0)], const {}),
      failureWith('no geometry for prototype sculpture'),
    );
    for (final counts in <List<int>>[
      [],
      [0],
      [-1],
    ]) {
      expect(
        () => VrlwSceneAdapter.validateActiveGeometry(
          [entity(0)],
          {'sculpture': counts},
        ),
        throwsFormatException,
      );
    }
  });
}
