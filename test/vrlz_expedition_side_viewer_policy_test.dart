import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_apps/src/viewer/vrlz_expedition_presenter.dart';
import 'package:vrlizate_apps/src/viewer/vrlz_expedition_task.dart';
import 'package:vrlizate_apps/vrlizate_apps_expedition.dart';

final class _Store implements VrlzExpeditionPersistence {
  Uint8List? bytes;
  bool fail = false;
  @override
  Future<Uint8List?> read(String id) async => bytes;
  @override
  Future<void> write(String id, Uint8List data) async {
    if (fail) throw StateError('simulated write failure');
    bytes = Uint8List.fromList(data);
  }
}

VrlzExpeditionGiver _giver(String id) => VrlzExpeditionGiver(
  id: id,
  name: 'Luma',
  dialogue: '¿Qué historia quieres explorar?',
  species: 'axolotl',
  position: [8, 0, 24],
);
VrlzExpeditionObject _object(String id) => VrlzExpeditionObject(
  id: id,
  label: 'Archivo del viaje',
  kind: 'examine',
  position: [17, 1.4, 17],
  radius: 2,
);
VrlzExpeditionDefinition _definition({
  bool longText = false,
}) => VrlzExpeditionDefinition(
  id: 'side-viewer',
  experienceId: 'worlds',
  title: 'Expedición',
  revision: 1,
  worlds: {
    'garden': 'Jardín',
    'museum': 'Museo',
    'neon': 'Distrito neón',
    'polar': 'Estación polar',
  },
  missions: [
    VrlzExpeditionMission(
      id: 'unlock',
      world: 'garden',
      title: 'Inicio',
      instruction: 'Observa',
      discovery: 'Una entrada',
      position: [8, 1.6, 12],
    ),
    VrlzExpeditionMission(
      id: 'main',
      world: 'garden',
      title: 'Misión principal',
      instruction: 'Registra la muestra',
      discovery: 'La muestra',
      position: [17, 1.4, 17],
      giver: _giver('main-guide'),
      object: _object('main-object'),
    ),
  ],
  sideQuests: [
    for (final id in ['story', 'other'])
      VrlzExpeditionSideQuest(
        id: id,
        title: id == 'story' ? 'Dos relatos' : 'Otro relato',
        afterMissionId: 'unlock',
        world: 'garden',
        giver: _giver('guide-$id'),
        choices: [
          VrlzExpeditionChoice(
            id: 'heritage',
            label: 'Conservar la memoria del museo',
            dialogue: longText
                ? '${List.filled(40, 'La memoria permanece').join(' ')} FINAL-REACCION'
                : 'Luma agradece que protejas el archivo.',
            discovery: 'Se preservó la memoria original.',
            route: ['museum', 'polar'],
            object: _object('archive-$id'),
          ),
          VrlzExpeditionChoice(
            id: 'future',
            label: 'Compartir la señal del futuro',
            dialogue: 'Luma celebra una señal abierta.',
            discovery: 'La señal conectó a la comunidad.',
            route: ['neon'],
            object: _object('signal-$id'),
          ),
        ],
      ),
  ],
);
Future<VrlzExpeditionController> _controller(
  _Store store, {
  bool unlock = true,
  bool longText = false,
}) async {
  final controller = VrlzExpeditionController(
    definition: _definition(longText: longText),
    store: store,
  );
  await controller.restore();
  controller.visit('garden');
  if (unlock && !controller.completedMissions.containsKey('unlock')) {
    controller.complete('unlock', 'garden', [8, 1.6, 12]);
  }
  return controller;
}

const _giverEye = <double>[8, 1.6, 24], _objectEye = <double>[17, 1.6, 17];
List<VrlzPassportAction> _actions(VrlzPassportPresentation p) =>
    p.pages.expand((p) => p.actions).toList();
Future<void> _close(VrlzExpeditionController c) async {
  await c.flush();
  c.dispose();
}

void main() {
  test(
    'finishing main campaign keeps incomplete histories distinct and counts delivered stories',
    () async {
      final controller = await _controller(_Store());
      controller.accept('main', 'garden', _giverEye);
      controller.interact('main', 'garden', _objectEye);
      controller.complete('main', 'garden', _giverEye);
      final before = VrlzPassportPresentation(controller);
      expect(
        before.progress,
        contains('Historias completadas: 0 · Disponibles: 2'),
      );
      expect(
        before.pages.map((p) => p.body).join('\n'),
        contains('Campaña principal completada'),
      );
      controller.focusSideQuest('story');
      controller.chooseSideQuest('story', 'future', 'garden', _giverEye);
      controller.visit('neon');
      controller.interactSideQuest('story', 'neon', _objectEye);
      controller.completeSideQuest('story', 'garden', _giverEye);
      expect(
        VrlzPassportPresentation(controller).progress,
        contains('Historias completadas: 1 · Disponibles: 1'),
      );
      await _close(controller);
    },
  );
  test('a save resolved after pause cannot open another world', () async {
    const guard = VrlzExpeditionTravelGuard(2, 4);
    final saved = Completer<void>();
    var active = true, opened = false;
    final pending = () async {
      await saved.future;
      if (guard.permits(
        mounted: true,
        active: active,
        exiting: false,
        hasError: false,
        currentGeneration: 2,
        currentNavigation: 4,
      )) {
        opened = true;
      }
    }();
    active = false;
    saved.complete();
    await pending;
    expect(opened, isFalse);
    expect(
      guard.permits(
        mounted: true,
        active: true,
        exiting: false,
        hasError: false,
        currentGeneration: 2,
        currentNavigation: 4,
      ),
      isTrue,
    );
    expect(
      guard.permits(
        mounted: true,
        active: true,
        exiting: false,
        hasError: false,
        currentGeneration: 2,
        currentNavigation: 5,
      ),
      isFalse,
    );
    expect(
      guard.permits(
        mounted: true,
        active: true,
        exiting: false,
        hasError: true,
        currentGeneration: 2,
        currentNavigation: 4,
      ),
      isFalse,
    );
    expect(
      guard.permits(
        mounted: false,
        active: true,
        exiting: false,
        hasError: false,
        currentGeneration: 2,
        currentNavigation: 4,
      ),
      isFalse,
    );
  });
  test(
    'locked stories do not appear; unlocked stories expose explicit follow action',
    () async {
      final controller = await _controller(_Store(), unlock: false);
      expect(
        VrlzPassportPresentation(
          controller,
        ).pages.any((p) => p.sideQuestId != null),
        isFalse,
      );
      controller.complete('unlock', 'garden', [8, 1.6, 12]);
      final p = VrlzPassportPresentation(controller);
      final follow = _actions(
        p,
      ).firstWhere((a) => a.kind == VrlzPassportActionKind.focusSide);
      expect(
        follow.canRun(controller, 'garden', _giverEye, dialogue: false),
        isTrue,
      );
      expect(controller.focusedSideQuestId, isNull);
      expect(controller.sideProgress, isEmpty);
      await _close(controller);
    },
  );

  test(
    'focused story replaces main actor and splits giver/object worlds',
    () async {
      final controller = await _controller(_Store());
      controller.focusSideQuest('story');
      final offer = VrlzExpeditionTask.current(controller);
      expect(offer.isSide, isTrue);
      expect(offer.actorId, 'side_story');
      expect(offer.showGiver('garden'), isTrue);
      expect(offer.showGiver('polar'), isFalse);
      expect(offer.showObject('garden'), isFalse);
      expect(offer.object, isNull);
      expect(offer.canTalk('garden', _giverEye), isTrue);
      expect(offer.canTalk('neon', _giverEye), isFalse);
      expect(controller.nextMission!.id, 'main');
      await _close(controller);
    },
  );

  test(
    'dialogue exposes both complete labels, reactions and actual routes before accepting',
    () async {
      final controller = await _controller(_Store());
      controller.focusSideQuest('story');
      final normal = VrlzPassportPresentation(controller);
      expect(
        _actions(
          normal,
        ).where((a) => a.kind == VrlzPassportActionKind.chooseSide),
        isEmpty,
      );
      final dialogue = VrlzPassportPresentation(controller, dialogue: true);
      final text = dialogue.pages.map((p) => p.body).join('\n');
      for (final phrase in [
        'Conservar la memoria del museo',
        'Compartir la señal del futuro',
        'Museo → Estación polar → Jardín',
        'Distrito neón → Jardín',
        'Luma agradece',
        'Luma celebra',
        'quedará registrada',
      ]) {
        expect(text, contains(phrase));
      }
      final choices = _actions(
        dialogue,
      ).where((a) => a.kind == VrlzPassportActionKind.chooseSide).toList();
      expect(choices.map((a) => a.choiceId).toSet(), {'heritage', 'future'});
      expect(choices.every((a) => a.label.startsWith('Aceptar ruta')), isTrue);
      expect(controller.sideProgress, isEmpty);
      await _close(controller);
    },
  );

  test(
    'choice buttons require current dialogue, correct world and proximity',
    () async {
      final controller = await _controller(_Store());
      controller.focusSideQuest('story');
      final choice = _actions(
        VrlzPassportPresentation(controller, dialogue: true),
      ).firstWhere((a) => a.kind == VrlzPassportActionKind.chooseSide);
      expect(
        choice.canRun(controller, 'garden', _giverEye, dialogue: true),
        isTrue,
      );
      expect(
        choice.canRun(controller, 'garden', _giverEye, dialogue: false),
        isFalse,
      );
      expect(
        choice.canRun(controller, 'neon', _giverEye, dialogue: true),
        isFalse,
      );
      expect(
        choice.canRun(controller, 'garden', [8, 1.6, 12], dialogue: true),
        isFalse,
      );
      expect(
        choice.canRun(controller, 'garden', [
          double.nan,
          1.6,
          24,
        ], dialogue: true),
        isFalse,
      );
      controller.focusSideQuest(null);
      expect(
        choice.canRun(controller, 'garden', _giverEye, dialogue: true),
        isFalse,
      );
      await _close(controller);
    },
  );

  for (final (choiceId, expected) in [
    ('heritage', 'museum'),
    ('future', 'neon'),
  ]) {
    test(
      '$choiceId changes real contextual destination and keeps main mission',
      () async {
        final controller = await _controller(_Store());
        controller.focusSideQuest('story');
        controller.chooseSideQuest('story', choiceId, 'garden', _giverEye);
        expect(VrlzPassportPresentation(controller).nextWorld, expected);
        final route = VrlzExpeditionRoute.current(controller, 'garden')!;
        expect(route.destination, expected);
        expect(
          route.canTravel(controller, 'garden', [8, 1.6, 12], route.name),
          isTrue,
        );
        expect(
          route.canTravel(controller, 'garden', [8, 1.6, 24], route.name),
          isFalse,
        );
        expect(
          route.canTravel(controller, 'garden', [8, 1.6, 12], 'stale'),
          isFalse,
        );
        expect(VrlzExpeditionRoute.current(controller, expected), isNull);
        expect(controller.nextMission!.id, 'main');
        await _close(controller);
      },
    );
  }

  test(
    'route checkpoints change identity; stale entry cannot skip later stop',
    () async {
      final controller = await _controller(_Store());
      controller.focusSideQuest('story');
      controller.chooseSideQuest('story', 'heritage', 'garden', _giverEye);
      final first = VrlzExpeditionRoute.current(controller, 'garden')!;
      controller.visit('museum');
      final second = VrlzExpeditionRoute.current(controller, 'museum')!;
      expect(second.destination, 'polar');
      expect(second.name, isNot(first.name));
      expect(
        first.canTravel(controller, 'garden', [8, 1.6, 12], first.name),
        isFalse,
      );
      expect(
        second.canTravel(controller, 'museum', [8, 1.6, 12], second.name),
        isTrue,
      );
      controller.focusSideQuest(null);
      expect(
        second.canTravel(controller, 'museum', [8, 1.6, 12], second.name),
        isFalse,
      );
      await _close(controller);
    },
  );

  test(
    'object appears only at final world after ordered checkpoints; no NPC there',
    () async {
      final controller = await _controller(_Store());
      controller.focusSideQuest('story');
      controller.chooseSideQuest('story', 'heritage', 'garden', _giverEye);
      controller.visit('polar');
      expect(
        VrlzExpeditionTask.current(controller).showObject('polar'),
        isFalse,
      );
      controller.visit('museum');
      controller.visit('polar');
      final task = VrlzExpeditionTask.current(controller);
      expect(task.showObject('polar'), isTrue);
      expect(task.showObject('museum'), isFalse);
      expect(task.showGiver('polar'), isFalse);
      expect(task.canInteract('polar', _objectEye), isTrue);
      expect(task.interact('polar', _objectEye), isTrue);
      expect(VrlzExpeditionTask.current(controller).collected, isTrue);
      expect(controller.sideDestination, 'garden');
      expect(
        VrlzExpeditionRoute.current(controller, 'polar')!.destination,
        'garden',
      );
      await _close(controller);
    },
  );

  test(
    'return to main preserves accepted main objective and pending side route',
    () async {
      final controller = await _controller(_Store());
      controller.accept('main', 'garden', _giverEye);
      controller.focusSideQuest('story');
      controller.chooseSideQuest('story', 'heritage', 'garden', _giverEye);
      controller.visit('museum');
      final returnMain = _actions(
        VrlzPassportPresentation(controller),
      ).firstWhere((a) => a.kind == VrlzPassportActionKind.focusMain);
      expect(
        returnMain.canRun(controller, 'museum', [8, 1.6, 12], dialogue: false),
        isTrue,
      );
      controller.focusSideQuest(null);
      final main = VrlzExpeditionTask.current(controller);
      expect(main.isSide, isFalse);
      expect(main.actorId, 'main');
      expect(main.accepted, isTrue);
      expect(controller.pendingSideQuestId, 'story');
      controller.focusSideQuest('story');
      expect(VrlzExpeditionTask.current(controller).destination, 'polar');
      await _close(controller);
    },
  );

  test(
    'pending story blocks other follow buttons but offers resume without losing choice',
    () async {
      final controller = await _controller(_Store());
      controller.focusSideQuest('story');
      controller.chooseSideQuest('story', 'future', 'garden', _giverEye);
      controller.focusSideQuest(null);
      final p = VrlzPassportPresentation(controller);
      final other = p.pages.where((p) => p.sideQuestId == 'other');
      expect(
        other.any((p) => p.body.contains('Termina la secundaria pendiente')),
        isTrue,
      );
      expect(other.expand((p) => p.actions), isEmpty);
      final resume = _actions(p).firstWhere(
        (a) =>
            a.questId == 'story' && a.kind == VrlzPassportActionKind.focusSide,
      );
      expect(resume.label, 'Retomar secundaria');
      expect(
        resume.canRun(controller, 'garden', _giverEye, dialogue: false),
        isTrue,
      );
      await _close(controller);
    },
  );

  test(
    'return dialogue completes chosen story and journals only chosen discovery',
    () async {
      final controller = await _controller(_Store());
      controller.focusSideQuest('story');
      controller.chooseSideQuest('story', 'future', 'garden', _giverEye);
      controller.visit('neon');
      controller.interactSideQuest('story', 'neon', _objectEye);
      final dialogue = VrlzPassportPresentation(controller, dialogue: true);
      final deliver = _actions(
        dialogue,
      ).firstWhere((a) => a.kind == VrlzPassportActionKind.returnSide);
      expect(
        deliver.canRun(controller, 'garden', _giverEye, dialogue: true),
        isTrue,
      );
      expect(
        deliver.canRun(controller, 'neon', _giverEye, dialogue: true),
        isFalse,
      );
      expect(
        deliver.canRun(controller, 'garden', _giverEye, dialogue: false),
        isFalse,
      );
      controller.completeSideQuest('story', 'garden', _giverEye);
      final journal = VrlzPassportPresentation(controller);
      final text = journal.pages
          .where((p) => p.sideQuestId == 'story')
          .map((p) => p.body)
          .join('\n');
      expect(journal.sideQuestPage('story'), greaterThanOrEqualTo(0));
      expect(text, contains('Historia completada'));
      expect(text, contains('La señal conectó a la comunidad.'));
      expect(text, isNot(contains('Se preservó la memoria original.')));
      expect(controller.focusedSideQuestId, isNull);
      await _close(controller);
    },
  );

  test(
    'restore resumes exact focused route and stable marker identity without new choice',
    () async {
      final store = _Store();
      final first = await _controller(store);
      first.focusSideQuest('story');
      first.chooseSideQuest('story', 'heritage', 'garden', _giverEye);
      first.visit('museum');
      final name = VrlzExpeditionRoute.current(first, 'museum')!.name;
      await _close(first);
      final restored = await _controller(store);
      expect(restored.focusedSideQuestId, 'story');
      expect(restored.focusedSideChoice!.id, 'heritage');
      expect(VrlzExpeditionRoute.current(restored, 'museum')!.name, name);
      final p = VrlzPassportPresentation(restored, dialogue: true);
      expect(p.nextWorld, 'polar');
      expect(
        _actions(p).where((a) => a.kind == VrlzPassportActionKind.chooseSide),
        isEmpty,
      );
      await _close(restored);
    },
  );

  test(
    'long decision reactions remain paginated and both choices stay reachable',
    () async {
      final controller = await _controller(_Store(), longText: true);
      controller.focusSideQuest('story');
      final p = VrlzPassportPresentation(controller, dialogue: true);
      expect(p.pages.every((p) => p.body.length <= 360), isTrue);
      expect(p.pages.map((p) => p.body).join('\n'), contains('FINAL-REACCION'));
      final pages = p.pages.where(
        (p) =>
            p.actions.any((a) => a.kind == VrlzPassportActionKind.chooseSide),
      );
      expect(pages.length, greaterThan(1));
      expect(pages.every((p) => p.actions.length == 2), isTrue);
      expect(
        pages.every(
          (p) => p.actions.map((a) => a.choiceId).toSet().containsAll([
            'heritage',
            'future',
          ]),
        ),
        isTrue,
      );
      await _close(controller);
    },
  );

  test(
    'save failure keeps recorded decision visible and resumable without claiming durability',
    () async {
      final store = _Store();
      final controller = await _controller(store);
      controller.focusSideQuest('story');
      store.fail = true;
      controller.chooseSideQuest('story', 'future', 'garden', _giverEye);
      expect(await controller.flush(), isFalse);
      final p = VrlzPassportPresentation(controller);
      expect(p.saveStatus, contains('Guardado pendiente'));
      expect(p.nextWorld, 'neon');
      expect(
        p.pages.map((p) => p.body).join('\n'),
        contains('Compartir la señal del futuro'),
      );
      store.fail = false;
      await _close(controller);
    },
  );
}
