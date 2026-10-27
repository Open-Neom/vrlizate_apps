import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_apps/vrlizate_apps_expedition.dart';

import 'support/vrlz_expedition_fixture.dart';

void main() {
  test(
    'expanded counts and campaign bytes remain bounded independently of saves',
    () {
      expect(VrlzExpeditionDefinition.maxSideQuests, 40);
      expect(VrlzExpeditionDefinition.maxWorldChanges, 80);
      expect(VrlzExpeditionDefinition.maxBytes, 256 * 1024);
      expect(VrlzExpeditionController.maxSnapshotBytes, 32 * 1024);
      final definition = _construct(_raw());
      final bytes = _bytes(definition.toJson());
      expect(bytes.length, greaterThan(128 * 1024));
      expect(bytes.length, lessThanOrEqualTo(256 * 1024));
      expect(definition.worlds.length, 32);
      expect(definition.missions.length, 128);
      expect(definition.sideQuests.length, 40);
      expect(definition.worldChanges.length, 80);
      expect(
        definition.estimatedSnapshotUpperBoundBytes,
        lessThanOrEqualTo(32 * 1024),
      );
      expect(
        VrlzExpeditionDefinition.fromBytes(bytes).toJson(),
        definition.toJson(),
      );
      expect(
        () => VrlzExpeditionDefinition.fromBytes(Uint8List(256 * 1024 + 1)),
        throwsFormatException,
      );
      expect(
        () => _construct(_raw(dialogueLength: 1024)),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            contains('256 KiB'),
          ),
        ),
      );
    },
  );

  test('41 stories and 81 interventions are rejected before play', () {
    expect(() => _construct(_raw(sides: 41)), throwsArgumentError);
    expect(
      () => VrlzExpeditionDefinition.fromJson(_raw(sides: 41)),
      throwsFormatException,
    );
    expect(() => _construct(_raw(changes: 81)), throwsArgumentError);
    expect(
      () => VrlzExpeditionDefinition.fromJson(_raw(changes: 81)),
      throwsFormatException,
    );
  });

  test(
    'long maximum-count identifiers cannot create an unsaveable campaign',
    () {
      final tooLarge = _raw(idLength: 128);
      expect(
        () => _construct(tooLarge),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            contains('progress can exceed 32 KiB'),
          ),
        ),
      );
      expect(
        () => VrlzExpeditionDefinition.fromJson(tooLarge),
        throwsFormatException,
      );
      // Existing upper count of sixteen stories remains valid with the same IDs.
      final previous = _construct(_raw(idLength: 128, sides: 16, changes: 32));
      expect(
        previous.estimatedSnapshotUpperBoundBytes,
        lessThanOrEqualTo(32 * 1024),
      );
    },
  );

  test('near-budget identifiers preserve the same 32 KiB authoring guard', () {
    final definition = _construct(_raw(idLength: 96));
    expect(
      definition.estimatedSnapshotUpperBoundBytes,
      inExclusiveRange(32 * 1024 - 256, 32 * 1024),
    );
    expect(definition.estimatedSnapshotUpperBoundBytes, 32599);
    // The previous 32-story limit could safely retain longer identifiers.
    expect(
      _construct(
        _raw(idLength: 106, sides: 32, changes: 64),
      ).estimatedSnapshotUpperBoundBytes,
      32547,
    );
    final tooLarge = _raw(idLength: 97);
    expect(
      () => _construct(tooLarge),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.message,
          'message',
          contains('progress can exceed 32 KiB'),
        ),
      ),
    );
    expect(
      () => VrlzExpeditionDefinition.fromJson(tooLarge),
      throwsFormatException,
    );
  });

  for (final idLength in [80, 96]) {
    test(
      'maximum counts with $idLength-character IDs save every stamp, main mission and completed story below 32 KiB',
      () async {
        final definition = _construct(_raw(idLength: idLength)),
            store = ExpeditionMemoryStore();
        final c = VrlzExpeditionController(
          definition: definition,
          store: store,
        );
        await c.restore();
        _visitAll(c);
        _finishMain(c, definition.missions.length);
        for (final quest in definition.sideQuests) {
          _finishSide(c, quest);
        }
        expect(await c.flush(), isTrue);
        _checkSize('complete_ids_$idLength', definition, store.bytes!);
        if (idLength == 96) {
          expect(store.bytes!.length, inExclusiveRange(31 * 1024, 32 * 1024));
        }
        final reload = VrlzExpeditionController(
          definition: definition,
          store: store,
        );
        await reload.restore();
        expect(reload.visitedWorlds.length, 32);
        expect(reload.completedMissions.length, 128);
        expect(reload.sideProgress.length, 40);
        expect(
          reload.sideProgress.values.every(
            (progress) => progress.completedAt != null,
          ),
          isTrue,
        );
        expect(reload.focusedSideQuestId, isNull);
        expect(reload.pendingSideQuestId, isNull);
        expect(
          reload.worldChange(definition.worlds.keys.first)?.id,
          'impact_0',
        );
        c.dispose();
        reload.dispose();
      },
    );
  }

  for (final collected in [false, true]) {
    test(
      'maximum pending ${collected ? 'collected' : 'accepted'} stages and focus reload safely',
      () async {
        final definition = _construct(_raw()), store = ExpeditionMemoryStore();
        final c = VrlzExpeditionController(
          definition: definition,
          store: store,
        );
        await c.restore();
        _visitAll(c);
        _finishMain(c, 127);
        final main = c.nextMission!;
        expect(c.accept(main.id, main.world, main.giver!.position), isTrue);
        if (collected) {
          expect(
            c.interact(main.id, main.world, main.object!.position),
            isTrue,
          );
        }
        for (final quest in definition.sideQuests.take(
          definition.sideQuests.length - 1,
        )) {
          _finishSide(c, quest);
        }
        final side = definition.sideQuests.last,
            choice = definition.sideQuests.last.choices.first;
        expect(
          c.chooseSideQuest(
            side.id,
            choice.id,
            side.world,
            side.giver.position,
          ),
          isTrue,
        );
        expect(c.visit(choice.route.last), isTrue);
        if (collected) {
          expect(
            c.interactSideQuest(
              side.id,
              choice.route.last,
              choice.object.position,
            ),
            isTrue,
          );
        }
        if (!collected) expect(c.focusSideQuest(null), isTrue);
        expect(await c.flush(), isTrue);
        _checkSize(
          collected ? 'pending_collected' : 'pending_accepted',
          definition,
          store.bytes!,
        );
        expect(store.bytes!.length, inExclusiveRange(31 * 1024, 32 * 1024));
        final reload = VrlzExpeditionController(
          definition: definition,
          store: store,
        );
        await reload.restore();
        expect(reload.completedMissions.length, 127);
        expect(reload.acceptedMissionId, main.id);
        expect(reload.objectiveCollected, collected);
        expect(reload.sideProgress.length, 40);
        expect(reload.pendingSideQuestId, side.id);
        expect(reload.sideProgress[side.id]?.collected, collected);
        expect(reload.focusedSideQuestId, collected ? side.id : null);
        c.dispose();
        reload.dispose();
      },
    );
  }

  for (final priorStoryCount in [14, 24, 32]) {
    test(
      'a $priorStoryCount-story passport survives expansion without rewriting prior progress',
      () async {
        final previous = _construct(
          _raw(
            sides: priorStoryCount,
            changes: priorStoryCount * 2,
            instructionLength: 1,
          ),
        );
        final store = ExpeditionMemoryStore();
        final old = VrlzExpeditionController(
          definition: previous,
          store: store,
        );
        await old.restore();
        _visitAll(old);
        _finishMain(old, 2);
        _finishSide(old, previous.sideQuests.first);
        final side = previous.sideQuests[1],
            choice = previous.sideQuests[1].choices.first;
        old.chooseSideQuest(
          side.id,
          choice.id,
          side.world,
          side.giver.position,
        );
        expect(await old.flush(), isTrue);
        final saved = Uint8List.fromList(store.bytes!), writes = store.writes;
        old.dispose();
        final c = VrlzExpeditionController(
          definition: _construct(_raw()),
          store: store,
        );
        await c.restore();
        expect(c.completedMissions.length, 2);
        expect(c.sideProgress.length, 2);
        expect(c.pendingSideQuestId, side.id);
        expect(c.focusedSideQuestId, side.id);
        expect(c.definition.revision, 1);
        expect(await c.flush(), isTrue);
        expect(store.bytes, saved);
        expect(store.writes, writes);
        c.dispose();
      },
    );
  }
}

void _checkSize(
  String label,
  VrlzExpeditionDefinition definition,
  Uint8List bytes,
) {
  expect(
    bytes.length,
    lessThanOrEqualTo(definition.estimatedSnapshotUpperBoundBytes),
  );
  expect(bytes.length, lessThanOrEqualTo(32 * 1024));
  // ignore: avoid_print
  print(
    jsonEncode({
      'capacity': label,
      'snapshotBytes': bytes.length,
      'upperBoundBytes': definition.estimatedSnapshotUpperBoundBytes,
    }),
  );
}

void _visitAll(VrlzExpeditionController c) {
  for (final world in c.definition.worlds.keys) {
    c.visit(world);
  }
}

void _finishMain(VrlzExpeditionController c, int count) {
  for (var n = 0; n < count; n++) {
    final mission = c.nextMission!;
    expect(
      c.accept(mission.id, mission.world, mission.giver!.position),
      isTrue,
    );
    expect(
      c.interact(mission.id, mission.world, mission.object!.position),
      isTrue,
    );
    expect(
      c.complete(mission.id, mission.world, mission.giver!.position),
      isTrue,
    );
  }
}

void _finishSide(VrlzExpeditionController c, VrlzExpeditionSideQuest side) {
  final choice = side.choices.first;
  expect(
    c.chooseSideQuest(side.id, choice.id, side.world, side.giver.position),
    isTrue,
  );
  expect(c.visit(choice.route.last), isTrue);
  expect(
    c.interactSideQuest(side.id, choice.route.last, choice.object.position),
    isTrue,
  );
  expect(c.completeSideQuest(side.id, side.world, side.giver.position), isTrue);
}

Uint8List _bytes(Object value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));
String _id(String prefix, int index, int length) =>
    '$prefix${index.toString().padLeft(length - prefix.length, '0')}';
Map<String, dynamic> _raw({
  int idLength = 96,
  int sides = 40,
  int changes = 80,
  int instructionLength = 600,
  int dialogueLength = 1,
}) {
  final worlds = [for (var n = 0; n < 32; n++) _id('w', n, idLength)];
  final mains = [for (var n = 0; n < 128; n++) _id('m', n, idLength)];
  final stories = [for (var n = 0; n < sides; n++) _id('s', n, idLength)];
  Map<String, dynamic> giver() => {
    'id': 'giver',
    'name': 'G',
    'dialogue': 'D' * dialogueLength,
    'species': 'robot',
    'position': <double>[0, 1.6, 0],
    'radius': 2.5,
  };
  Map<String, dynamic> object() => {
    'id': 'object',
    'label': 'O',
    'kind': 'collect',
    'position': <double>[0, 1.6, 0],
    'radius': 2.5,
  };
  return {
    'schemaVersion': 1,
    'id': 'capacity',
    'experienceId': 'capacity.worlds',
    'title': 'Capacity',
    'revision': 1,
    'worlds': {for (final world in worlds) world: 'W'},
    'missions': [
      for (final id in mains)
        {
          'id': id,
          'world': worlds.first,
          'title': 'M',
          'instruction': 'I' * instructionLength,
          'discovery': 'D',
          'position': <double>[0, 1.6, 0],
          'radius': 2.5,
          'giver': giver(),
          'object': object(),
        },
    ],
    'sideQuests': [
      for (final id in stories)
        {
          'id': id,
          'title': 'S',
          'afterMissionId': mains.first,
          'world': worlds.first,
          'giver': giver(),
          'choices': [
            for (var n = 0; n < 2; n++)
              {
                'id': _id('c', n, idLength),
                'label': 'C',
                'dialogue': 'D',
                'discovery': 'D',
                'route': [worlds[1]],
                'object': object(),
              },
          ],
        },
    ],
    'worldChanges': [
      for (var n = 0; n < changes; n++)
        {
          'id': 'impact_$n',
          'world': worlds.first,
          'requires': [
            {
              'questId': stories[n % stories.length],
              'choiceIds': [_id('c', 0, idLength)],
            },
          ],
          'prop': {
            'kind': 'planter',
            'label': 'P',
            'description': 'D',
            'position': <double>[3, 0, 5],
            'radius': 2.5,
          },
        },
    ],
  };
}

VrlzExpeditionDefinition _construct(
  Map<String, dynamic> json,
) => VrlzExpeditionDefinition(
  id: json['id'] as String,
  experienceId: json['experienceId'] as String,
  title: json['title'] as String,
  revision: json['revision'] as int,
  worlds: Map<String, String>.from(json['worlds'] as Map),
  missions: [
    for (final mission in json['missions'] as List)
      VrlzExpeditionMission.fromJson(Map<String, dynamic>.from(mission as Map)),
  ],
  sideQuests: [
    for (final side in json['sideQuests'] as List)
      VrlzExpeditionSideQuest.fromJson(Map<String, dynamic>.from(side as Map)),
  ],
  worldChanges: [
    for (final change in json['worldChanges'] as List)
      VrlzExpeditionWorldChange.fromJson(
        Map<String, dynamic>.from(change as Map),
      ),
  ],
);
