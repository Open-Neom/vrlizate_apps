import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_apps/src/viewer/vrlz_expedition_presenter.dart';
import 'package:vrlizate_apps/src/viewer/vrlz_expedition_task.dart';
import 'package:vrlizate_apps/vrlizate_apps_expedition.dart';

final class _Store implements VrlzExpeditionPersistence {
  Uint8List? bytes;
  @override
  Future<Uint8List?> read(String id) async => bytes;
  @override
  Future<void> write(String id, Uint8List data) async =>
      bytes = Uint8List.fromList(data);
}

VrlzExpeditionStoryRequirement _requires(String quest, String choice) =>
    VrlzExpeditionStoryRequirement(questId: quest, choiceIds: [choice]);
VrlzExpeditionSideQuest _quest(
  String id,
  String title, {
  List<VrlzExpeditionStoryRequirement> requires = const [],
  List<VrlzExpeditionDialogueVariant> dialogueVariants = const [],
}) => VrlzExpeditionSideQuest(
  id: id,
  title: title,
  afterMissionId: 'unlock',
  world: 'garden',
  requires: requires,
  dialogueVariants: dialogueVariants,
  giver: VrlzExpeditionGiver(
    id: 'guide-$id',
    name: 'Luma',
    dialogue: 'BASE-$id',
    species: 'sprout',
    position: [8, 0, 24],
  ),
  choices: [
    for (final choice in ['keep', 'share'])
      VrlzExpeditionChoice(
        id: choice,
        label: 'Elección $choice',
        dialogue: 'REACCION-$id-$choice',
        discovery: 'DESCUBRIMIENTO-$id-$choice',
        route: ['archive'],
        object: VrlzExpeditionObject(
          id: 'object-$id-$choice',
          label: 'Archivo',
          kind: 'examine',
          position: [17, 1.4, 17],
          radius: 2,
        ),
      ),
  ],
);
VrlzExpeditionDefinition _definition({int extraContinuations = 0}) =>
    VrlzExpeditionDefinition(
      id: 'connected-viewer',
      experienceId: 'worlds',
      title: 'Historias conectadas',
      revision: 1,
      worlds: {'garden': 'Jardín', 'archive': 'Archivo'},
      missions: [
        VrlzExpeditionMission(
          id: 'unlock',
          world: 'garden',
          title: 'Inicio',
          instruction: 'Observa',
          discovery: 'La entrada',
          position: [8, 1.6, 12],
        ),
      ],
      sideQuests: [
        _quest('origin', 'Encuentro inicial'),
        _quest('memory', 'Voz de Niva'),
        _quest(
          'keep-chapter',
          'CAPITULO_CONSERVADO',
          requires: [_requires('origin', 'keep')],
          dialogueVariants: [
            VrlzExpeditionDialogueVariant(
              requires: [_requires('memory', 'keep')],
              dialogue: 'RECUERDO_DEL_SILENCIO',
            ),
            VrlzExpeditionDialogueVariant(
              requires: [_requires('memory', 'share')],
              dialogue: 'RECUERDO_DE_LA_MUSICA',
            ),
          ],
        ),
        _quest(
          'share-chapter',
          'CAPITULO_PUBLICADO',
          requires: [_requires('origin', 'share')],
        ),
        _quest(
          'both-chapter',
          'LAS_DOS_VOCES',
          requires: [_requires('origin', 'keep'), _requires('memory', 'keep')],
        ),
        for (var i = 0; i < extraContinuations; i++)
          _quest(
            'extra-$i',
            'CONTINUACION_$i',
            requires: [_requires('origin', 'keep')],
          ),
      ],
    );
Future<VrlzExpeditionController> _open(
  _Store store, {
  int extraContinuations = 0,
}) async {
  final c = VrlzExpeditionController(
    definition: _definition(extraContinuations: extraContinuations),
    store: store,
  );
  await c.restore();
  c.visit('garden');
  if (!c.completedMissions.containsKey('unlock')) {
    c.complete('unlock', 'garden', [8, 1.6, 12]);
  }
  return c;
}

const _eye = <double>[8, 1.6, 24], _object = <double>[17, 1.6, 17];
String _text(VrlzPassportPresentation p) =>
    p.pages.map((p) => '${p.title}\n${p.body}').join('\n');
List<VrlzPassportAction> _actions(VrlzPassportPresentation p) =>
    p.pages.expand((p) => p.actions).toList();
Future<void> _close(VrlzExpeditionController c) async {
  await c.flush();
  c.dispose();
}

void _start(VrlzExpeditionController c, String id, String choice) {
  expect(c.focusSideQuest(id), isTrue);
  expect(c.chooseSideQuest(id, choice, 'garden', _eye), isTrue);
  c.visit('archive');
  expect(c.interactSideQuest(id, 'archive', _object), isTrue);
}

void _finish(VrlzExpeditionController c, String id, String choice) {
  _start(c, id, choice);
  expect(c.completeSideQuest(id, 'garden', _eye), isTrue);
}

void main() {
  test(
    'every unlocked continuation is actionable on bounded journal pages',
    () async {
      final c = await _open(_Store(), extraContinuations: 5);
      _finish(c, 'origin', 'keep');
      final p = VrlzPassportPresentation(c);
      final journal = p.pages
          .where((page) => page.sideQuestId == 'origin')
          .toList();
      expect(
        journal.every(
          (page) => page.actions.length <= 2 && page.body.length <= 360,
        ),
        isTrue,
      );
      final follow = journal.expand((page) => page.actions).toList();
      expect(follow.map((action) => action.questId).toSet(), {
        'keep-chapter',
        for (var i = 0; i < 5; i++) 'extra-$i',
      });
      expect(
        follow.every(
          (action) => action.canRun(c, 'garden', _eye, dialogue: false),
        ),
        isTrue,
      );
      final lastAvailable = p.pages.lastIndexWhere(
        (page) => page.title.startsWith('Secundaria ·'),
      );
      final firstArchive = p.pages.indexWhere(
        (page) => page.title.startsWith('Historia ·'),
      );
      expect(lastAvailable, lessThan(firstArchive));
      expect(
        p.pages.indexWhere((page) => page.title.startsWith('Pasaporte ·')),
        lessThan(lastAvailable),
      );
      await _close(c);
    },
  );

  test(
    'locked chapter titles, dialogues and follow actions never reach passport',
    () async {
      final c = await _open(_Store());
      final p = VrlzPassportPresentation(c);
      for (final spoiler in [
        'CAPITULO_CONSERVADO',
        'CAPITULO_PUBLICADO',
        'LAS_DOS_VOCES',
        'RECUERDO_DEL_SILENCIO',
        'RECUERDO_DE_LA_MUSICA',
      ]) {
        expect(_text(p), isNot(contains(spoiler)));
      }
      expect(_actions(p).map((a) => a.questId).toSet(), {'origin', 'memory'});
      expect(p.progress, contains('Historias completadas: 0 · Disponibles: 2'));
      expect(p.progress, isNot(contains('/5')));
      const forged = VrlzPassportAction(
        VrlzPassportActionKind.focusSide,
        'Seguir',
        questId: 'keep-chapter',
      );
      expect(forged.canRun(c, 'garden', _eye, dialogue: false), isFalse);
      await _close(c);
    },
  );

  test(
    'choosing and collecting do not reveal continuation before delivery',
    () async {
      final c = await _open(_Store());
      _start(c, 'origin', 'keep');
      final p = VrlzPassportPresentation(c, dialogue: true);
      expect(_text(p), isNot(contains('CAPITULO_CONSERVADO')));
      expect(_text(p), isNot(contains('CAPITULO_PUBLICADO')));
      expect(p.progress, contains('Historias completadas: 0'));
      expect(_actions(p).any((a) => a.questId == 'keep-chapter'), isFalse);
      await _close(c);
    },
  );

  for (final (choice, shown, hidden) in [
    ('keep', 'CAPITULO_CONSERVADO', 'CAPITULO_PUBLICADO'),
    ('share', 'CAPITULO_PUBLICADO', 'CAPITULO_CONSERVADO'),
  ]) {
    test(
      'delivered $choice reveals only compatible continuation and immediate journal action',
      () async {
        final c = await _open(_Store());
        _finish(c, 'origin', choice);
        final p = VrlzPassportPresentation(c);
        final journal = p.pages.where((p) => p.sideQuestId == 'origin');
        expect(_text(p), contains(shown));
        expect(_text(p), isNot(contains(hidden)));
        expect(
          journal.first.body,
          startsWith('Historia completada. Entrega registrada.'),
        );
        expect(
          journal.map((p) => p.body).join('\n'),
          contains('Historias que habilita esta decisión'),
        );
        final follow = journal.expand((p) => p.actions).first;
        expect(follow.questId, '$choice-chapter');
        expect(follow.canRun(c, 'garden', _eye, dialogue: false), isTrue);
        expect(
          p.progress,
          contains('Historias completadas: 1 · Disponibles: 2'),
        );
        expect(p.progress, isNot(contains('/5')));
        await _close(c);
      },
    );
  }

  test(
    'AND dependent chapter stays hidden until both delivered histories match',
    () async {
      final c = await _open(_Store());
      _finish(c, 'origin', 'keep');
      expect(
        _text(VrlzPassportPresentation(c)),
        isNot(contains('LAS_DOS_VOCES')),
      );
      _start(c, 'memory', 'keep');
      expect(
        _text(VrlzPassportPresentation(c)),
        isNot(contains('LAS_DOS_VOCES')),
      );
      c.completeSideQuest('memory', 'garden', _eye);
      final p = VrlzPassportPresentation(c);
      expect(_text(p), contains('LAS_DOS_VOCES'));
      expect(_actions(p).any((a) => a.questId == 'both-chapter'), isTrue);
      expect(_text(p), isNot(contains('CAPITULO_PUBLICADO')));
      await _close(c);
    },
  );

  for (final (memoryChoice, expected, hidden) in [
    ('keep', 'RECUERDO_DEL_SILENCIO', 'RECUERDO_DE_LA_MUSICA'),
    ('share', 'RECUERDO_DE_LA_MUSICA', 'RECUERDO_DEL_SILENCIO'),
  ]) {
    test(
      'conversation and focused passport resolve delivered $memoryChoice memory after restore',
      () async {
        final store = _Store();
        final c = await _open(store);
        _finish(c, 'origin', 'keep');
        _finish(c, 'memory', memoryChoice);
        c.focusSideQuest('keep-chapter');
        final stamp = VrlzPassportPresentation.stamp(c);
        await _close(c);
        final restored = await _open(store);
        expect(VrlzPassportPresentation.stamp(restored), stamp);
        for (final dialogue in [false, true]) {
          final p = VrlzPassportPresentation(restored, dialogue: dialogue);
          final text = p.pages
              .where((p) => p.sideQuestId == 'keep-chapter')
              .map((p) => p.body)
              .join('\n');
          expect(text, contains(expected));
          expect(text, isNot(contains(hidden)));
          expect(text, isNot(contains('BASE-keep-chapter')));
        }
        final task = VrlzExpeditionTask.current(restored);
        expect(task.showGiver('garden'), isTrue);
        expect(task.actorId, 'side_keep-chapter');
        await _close(restored);
      },
    );
  }

  test(
    'unmatched memory uses fallback; recorded but undelivered choice cannot change dialogue',
    () async {
      final c = await _open(_Store());
      _finish(c, 'origin', 'keep');
      c.focusSideQuest('keep-chapter');
      expect(
        _text(VrlzPassportPresentation(c, dialogue: true)),
        contains('BASE-keep-chapter'),
      );
      c.focusSideQuest(null);
      _start(c, 'memory', 'keep');
      final chapter = c.definition.sideQuests.firstWhere(
        (q) => q.id == 'keep-chapter',
      );
      expect(c.sideQuestDialogue(chapter), 'BASE-keep-chapter');
      expect(
        _text(VrlzPassportPresentation(c)),
        isNot(contains('RECUERDO_DEL_SILENCIO')),
      );
      await _close(c);
    },
  );

  test(
    'journal continuation actions revalidate pending-story restriction',
    () async {
      final c = await _open(_Store());
      _finish(c, 'origin', 'keep');
      final follow = VrlzPassportPresentation(c).pages
          .where((p) => p.sideQuestId == 'origin')
          .expand((p) => p.actions)
          .first;
      _start(c, 'memory', 'share');
      expect(follow.canRun(c, 'garden', _eye, dialogue: false), isFalse);
      c.completeSideQuest('memory', 'garden', _eye);
      expect(follow.canRun(c, 'garden', _eye, dialogue: false), isTrue);
      await _close(c);
    },
  );

  test(
    'journal omits dead continuation buttons when already focused, blocked or completed',
    () async {
      final c = await _open(_Store());
      _finish(c, 'origin', 'keep');
      final initialFollow = VrlzPassportPresentation(c).pages
          .where((p) => p.sideQuestId == 'origin')
          .expand((p) => p.actions)
          .single;
      expect(initialFollow.questId, 'keep-chapter');

      // Already focused: no redundant/no-op button on journal page, and canRun is false.
      expect(c.focusSideQuest('keep-chapter'), isTrue);
      expect(initialFollow.canRun(c, 'garden', _eye, dialogue: false), isFalse);
      expect(
        VrlzPassportPresentation(c).pages
            .where((p) => p.sideQuestId == 'origin')
            .expand((p) => p.actions),
        isEmpty,
      );

      // Blocked by another pending quest: journal keeps text but emits no dead button.
      expect(c.focusSideQuest(null), isTrue);
      _start(c, 'memory', 'keep');
      final blockedJournal = VrlzPassportPresentation(
        c,
      ).pages.where((p) => p.sideQuestId == 'origin').toList();
      expect(
        blockedJournal.map((p) => p.body).join('\n'),
        contains('CAPITULO_CONSERVADO'),
      );
      expect(blockedJournal.expand((p) => p.actions), isEmpty);

      // Completed continuation: parent journal marks it completed and only offers remaining uncompleted continuations.
      c.completeSideQuest('memory', 'garden', _eye);
      _finish(c, 'keep-chapter', 'keep');
      var completedJournal = VrlzPassportPresentation(
        c,
      ).pages.where((p) => p.sideQuestId == 'origin').toList();
      expect(
        completedJournal.map((p) => p.body).join('\n'),
        contains('CAPITULO_CONSERVADO (completada)'),
      );
      expect(
        completedJournal.expand((p) => p.actions).map((a) => a.questId),
        ['both-chapter'],
      );
      _finish(c, 'both-chapter', 'keep');
      completedJournal = VrlzPassportPresentation(
        c,
      ).pages.where((p) => p.sideQuestId == 'origin').toList();
      expect(completedJournal.expand((p) => p.actions), isEmpty);
      await _close(c);
    },
  );

  test(
    'later NPC dialogue variants never rewrite delivered reaction or ending',
    () async {
      final c = await _open(_Store());
      _finish(c, 'origin', 'keep');
      _finish(c, 'keep-chapter', 'share');
      String chapterJournal() => VrlzPassportPresentation(c).pages
          .where((p) => p.sideQuestId == 'keep-chapter')
          .map((p) => p.body)
          .join('\n');
      final before = chapterJournal();
      expect(before, contains('REACCION-keep-chapter-share'));
      expect(before, contains('DESCUBRIMIENTO-keep-chapter-share'));
      _finish(c, 'memory', 'keep');
      expect(chapterJournal(), before);
      expect(chapterJournal(), isNot(contains('RECUERDO_DEL_SILENCIO')));
      await _close(c);
    },
  );
}
