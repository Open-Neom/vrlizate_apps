import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;
import 'package:vrlizate_apps/src/viewer/vrlz_expedition_actor.dart';
import 'package:vrlizate_apps/src/viewer/vrlz_expedition_occlusion.dart';
import 'package:vrlizate_apps/src/viewer/vrlz_expedition_presenter.dart';
import 'package:vrlizate_apps/vrlizate_apps_expedition.dart';
import 'package:vrlizate_avatar/vrlizate_avatar.dart';
import 'package:vrlizate_scene/vrlizate_scene.dart';

final class _Store implements VrlzExpeditionPersistence {
  Uint8List? bytes;
  @override
  Future<Uint8List?> read(String id) async => bytes;
  @override
  Future<void> write(String id, Uint8List data) async =>
      bytes = Uint8List.fromList(data);
}

VrlzExpeditionController _controller(_Store store, {String kind = 'collect'}) =>
    VrlzExpeditionController(
      definition: VrlzExpeditionDefinition(
        id: 'actors-test',
        experienceId: 'worlds-test',
        title: 'Expedición',
        revision: 1,
        worlds: {'reef': 'Arrecife'},
        missions: [
          VrlzExpeditionMission(
            id: 'research',
            world: 'reef',
            title: 'Observa el arrecife',
            instruction: 'Registra la muestra de coral.',
            discovery: 'El arrecife protege especies.',
            position: [17, 1.4, 17],
            giver: VrlzExpeditionGiver(
              id: 'guide',
              name: 'Luma',
              dialogue: 'Ayúdame a observar este ecosistema.',
              species: 'axolotl',
              position: [8, 0, 24],
            ),
            object: VrlzExpeditionObject(
              id: 'sample',
              label: 'Muestra de coral',
              kind: kind,
              position: [17, 1.4, 17],
              radius: 2,
            ),
            rewardId: VrAvatarCosmeticCatalog.canopy,
          ),
        ],
      ),
      store: store,
    );

const _giverEye = <double>[8, 1.6, 24];
const _objectEye = <double>[17, 1.6, 17];

void main() {
  test(
    'physical inspection is paginated in the existing passport without accepting or completing',
    () async {
      final controller = _controller(_Store());
      await controller.restore();
      controller.visit('reef');
      final stamp = VrlzPassportPresentation.stamp(controller);
      final prefix = VrlzPassportPresentation.inspection(
        'Jardinera del encuentro',
        '${List.filled(55, 'Una especie compartida.').join(' ')} FINAL-INSPECCION',
      );
      final p = VrlzPassportPresentation(controller, prefixPages: prefix);
      expect(p.pages.first.title, 'Jardinera del encuentro');
      expect(
        prefix.every((p) => p.body.length <= 360 && p.actions.isEmpty),
        isTrue,
      );
      expect(prefix.map((p) => p.body).join(' '), contains('FINAL-INSPECCION'));
      expect(
        p.pages.length,
        VrlzPassportPresentation(controller).pages.length + prefix.length,
      );
      expect(p.giverAction, VrlzGiverAction.none);
      expect(VrlzPassportPresentation.stamp(controller), stamp);
      expect(controller.acceptedMissionId, isNull);
      expect(controller.completedMissions, isEmpty);
      await controller.flush();
      controller.dispose();
    },
  );

  test(
    'same giver reaction prefixes dialogue but still requires the explicit mission action',
    () async {
      final controller = _controller(_Store());
      await controller.restore();
      controller.visit('reef');
      final reaction = VrlzPassportPresentation.inspection(
        'Luma · Tu decisión',
        'El espacio recuerda tu entrega.',
      );
      final p = VrlzPassportPresentation(
        controller,
        dialogue: true,
        prefixPages: reaction,
      );
      expect(p.pages.first.body, 'El espacio recuerda tu entrega.');
      expect(p.pages.skip(reaction.length).first.title, contains('Luma'));
      expect(p.giverAction, VrlzGiverAction.accept);
      expect(controller.acceptedMissionId, isNull);
      expect(controller.canComplete('research', 'reef', _giverEye), isFalse);
      await controller.flush();
      controller.dispose();
    },
  );

  test(
    'talking offers dialogue without accepting merely by proximity',
    () async {
      final controller = _controller(_Store());
      await controller.restore();
      controller.visit('reef');
      expect(
        VrlzExpeditionTaskPresentation.canTalk(controller, 'reef', _giverEye),
        isTrue,
      );
      final dialogue = VrlzPassportPresentation(controller, dialogue: true);
      expect(dialogue.pages.first.title, contains('Luma'));
      expect(dialogue.pages.first.body, contains('Ayúdame'));
      expect(dialogue.giverAction, VrlzGiverAction.accept);
      expect(
        VrlzPassportPresentation(controller).giverAction,
        VrlzGiverAction.none,
      );
      expect(controller.acceptedMissionId, isNull);
      expect(controller.canInteract('research', 'reef', _objectEye), isFalse);
      expect(controller.canComplete('research', 'reef', _giverEye), isFalse);
      await controller.flush();
      controller.dispose();
    },
  );

  for (final (kind, verb) in [
    ('collect', 'Recoge'),
    ('examine', 'Examina'),
    ('activate', 'Activa'),
  ]) {
    test(
      '$kind has explicit accept, objective and return stages with reward',
      () async {
        final controller = _controller(_Store(), kind: kind);
        await controller.restore();
        controller.visit('reef');
        final before = VrlzPassportPresentation.stamp(controller);
        expect(controller.accept('research', 'reef', _giverEye), isTrue);
        expect(VrlzPassportPresentation.stamp(controller), isNot(before));
        expect(
          VrlzExpeditionTaskPresentation.instruction(controller),
          startsWith(verb),
        );
        expect(
          VrlzPassportPresentation(controller, dialogue: true).giverAction,
          VrlzGiverAction.none,
        );
        expect(controller.interact('research', 'reef', _objectEye), isTrue);
        expect(
          VrlzExpeditionTaskPresentation.instruction(controller),
          contains('Vuelve con Luma'),
        );
        expect(
          VrlzPassportPresentation(controller, dialogue: true).giverAction,
          VrlzGiverAction.returnObject,
        );
        expect(controller.complete('research', 'reef', _objectEye), isFalse);
        expect(controller.rewardIds, isEmpty);
        expect(controller.complete('research', 'reef', _giverEye), isTrue);
        final passport = VrlzPassportPresentation(controller);
        final discovery = passport.pages[passport.discoveryPage('research')];
        expect(discovery.body, contains('Descubrimiento registrado'));
        expect(discovery.body, contains('Insignia del dosel'));
        expect(discovery.body, isNot(contains(VrAvatarCosmeticCatalog.canopy)));
        expect(controller.rewardIds, {VrAvatarCosmeticCatalog.canopy});
        await controller.flush();
        controller.dispose();
      },
    );
  }

  test(
    'restoring collected objective retains return dialogue and no repeat collection',
    () async {
      final store = _Store();
      final first = _controller(store);
      await first.restore();
      first.visit('reef');
      first.accept('research', 'reef', _giverEye);
      first.interact('research', 'reef', _objectEye);
      expect(await first.flush(), isTrue);
      first.dispose();
      final restored = _controller(store);
      await restored.restore();
      expect(restored.objectiveCollected, isTrue);
      expect(restored.canInteract('research', 'reef', _objectEye), isFalse);
      expect(
        VrlzPassportPresentation(restored, dialogue: true).giverAction,
        VrlzGiverAction.returnObject,
      );
      expect(
        VrlzExpeditionTaskPresentation.instruction(restored),
        contains('entregar'),
      );
      await restored.flush();
      restored.dispose();
    },
  );

  test(
    'talk gates full 3D distance, world, readiness and finite coordinates',
    () async {
      final controller = _controller(_Store());
      expect(
        VrlzExpeditionTaskPresentation.canTalk(controller, 'reef', _giverEye),
        isFalse,
      );
      await controller.restore();
      controller.visit('reef');
      for (final point in [
        <double>[8, 3, 24],
        <double>[12, 1.6, 24],
        <double>[double.nan, 1.6, 24],
        <double>[8, 24],
      ]) {
        expect(
          VrlzExpeditionTaskPresentation.canTalk(controller, 'reef', point),
          isFalse,
        );
      }
      expect(
        VrlzExpeditionTaskPresentation.canTalk(controller, 'other', _giverEye),
        isFalse,
      );
      await controller.flush();
      controller.dispose();
    },
  );

  test(
    'six real avatar plans fit mobile NPC bounds and unknown species is safe',
    () {
      var maxNearTriangles = 0,
          maxFarTriangles = 0,
          maxBatches = 0,
          maxParts = 0;
      for (final species in VrAvatarSpecies.values) {
        final appearance = VrlzExpeditionActor.appearance(species.name);
        expect(appearance.species, species);
        final plan = VrAvatarPlan.build(appearance);
        expect(plan.bounds.min.y, closeTo(0, 1e-6));
        expect(plan.bounds.max.y, closeTo(1.6, 1e-5));
        maxNearTriangles = math.max(
          maxNearTriangles,
          plan.triangleCount(VrAvatarDetail.near),
        );
        maxFarTriangles = math.max(
          maxFarTriangles,
          plan.triangleCount(VrAvatarDetail.far),
        );
        maxBatches = math.max(maxBatches, plan.batchCount(VrAvatarDetail.near));
        maxParts = math.max(maxParts, plan.parts.length);
      }
      expect(maxNearTriangles, lessThanOrEqualTo(12000));
      expect(maxFarTriangles, lessThanOrEqualTo(2500));
      expect(maxBatches, lessThanOrEqualTo(18));
      expect(maxParts, lessThanOrEqualTo(54));
      expect(
        VrlzExpeditionActor.appearance('future-species').species,
        VrAvatarSpecies.orb,
      );
      expect(
        VrlzExpeditionActor.appearance('droid').species,
        VrAvatarSpecies.robot,
      );
      // Report authoring cost, not a hardware FPS/draw-call measurement.
      // ignore: avoid_print
      print(
        'NPC plan maxima: near=$maxNearTriangles tris, far=$maxFarTriangles tris, batches=$maxBatches, parts=$maxParts',
      );
    },
  );

  final wall = Float32List.fromList([-2, -2, 0, 2, -2, 0, 2, 2, 0, -2, 2, 0]);
  const faces = <int>[0, 1, 2, 0, 2, 3];
  bool blocked(
    vm.Vector3 a,
    vm.Vector3 b, {
    vm.Matrix4? transform,
    List<int>? indices = faces,
  }) => VrlzExpeditionOcclusion.segmentBlocked(
    a,
    b,
    wall,
    indices: indices,
    transform: transform,
    bounds: vm.Aabb3.minMax(vm.Vector3(-2, -2, 0), vm.Vector3(2, 2, 0)),
  );

  test(
    'opaque walls block interactions from either side; clear paths remain usable',
    () {
      expect(blocked(vm.Vector3(0, 0, -1), vm.Vector3(0, 0, 1)), isTrue);
      expect(blocked(vm.Vector3(0, 0, 1), vm.Vector3(0, 0, -1)), isTrue);
      expect(blocked(vm.Vector3(3, 0, -1), vm.Vector3(3, 0, 1)), isFalse);
      expect(blocked(vm.Vector3(0, 0, -1), vm.Vector3(0, 0, -.2)), isFalse);
    },
  );

  test(
    'occlusion uses current translated, rotated and scaled geometry transforms',
    () {
      final transform = vm.Matrix4.identity()
        ..translateByDouble(4, 0, 0, 1)
        ..rotateY(math.pi / 2)
        ..scaleByDouble(2, 2, 2, 1);
      expect(
        blocked(vm.Vector3(3, 0, 0), vm.Vector3(5, 0, 0), transform: transform),
        isTrue,
      );
      transform.setTranslationRaw(8, 0, 0);
      expect(
        blocked(vm.Vector3(3, 0, 0), vm.Vector3(5, 0, 0), transform: transform),
        isFalse,
      );
    },
  );

  test('target endpoint and ground touch do not reject its own action', () {
    expect(blocked(vm.Vector3(0, 0, -1), vm.Vector3(0, 0, 0)), isFalse);
    expect(blocked(vm.Vector3(0, 0, -1), vm.Vector3(0, 0, .01)), isFalse);
    expect(blocked(vm.Vector3(0, 0, -1), vm.Vector3(0, 0, .1)), isTrue);
  });

  test(
    'occlusion fails closed on non-finite pose or non-invertible transform',
    () {
      expect(
        blocked(vm.Vector3(double.nan, 0, -1), vm.Vector3(0, 0, 1)),
        isTrue,
      );
      expect(
        blocked(
          vm.Vector3(0, 0, -1),
          vm.Vector3(0, 0, 1),
          transform: vm.Matrix4.zero(),
        ),
        isTrue,
      );
      expect(
        blocked(
          vm.Vector3(0, 0, -1),
          vm.Vector3(0, 0, 1),
          transform: vm.Matrix4.identity()..storage[0] = double.nan,
        ),
        isTrue,
      );
    },
  );

  test(
    'non-indexed triangle and bounds broadphase preserve segment semantics',
    () {
      final triangle = Float32List.fromList([-2, -2, 0, 2, -2, 0, 0, 2, 0]);
      expect(
        VrlzExpeditionOcclusion.segmentBlocked(
          vm.Vector3(0, 0, -1),
          vm.Vector3(0, 0, 1),
          triangle,
        ),
        isTrue,
      );
      expect(
        VrlzExpeditionActor.giverName('old'),
        isNot(VrlzExpeditionActor.giverName('current')),
      );
      expect(
        VrlzExpeditionActor.objectName('current'),
        isNot(VrlzExpeditionActor.giverName('current')),
      );
    },
  );
}
