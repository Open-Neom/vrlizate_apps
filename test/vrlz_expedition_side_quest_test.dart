import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_apps/vrlizate_apps_expedition.dart';

import 'support/vrlz_expedition_fixture.dart';

const _giver = <double>[0, 1.6, 0], _object = <double>[12, 1.6, 0];
const _time = '2026-10-26T00:00:00.000Z';

void main() {
  test(
    'side definitions round trip defensively without changing legacy bytes',
    () {
      final legacy = expeditionFixture();
      expect(legacy.sideQuests, isEmpty);
      expect(legacy.toJson().containsKey('sideQuests'), isFalse);
      final definition = _definition(), json = _definition().toJson();
      expect(VrlzExpeditionDefinition.fromJson(json).toJson(), json);
      expect(
        definition.missions.map((m) => m.id),
        legacy.missions.map((m) => m.id),
      );
      final choice = definition.sideQuests.first.choices.first;
      json['sideQuests'][0]['choices'][0]['route'][0] = 'changed';
      expect(choice.route, ['ridge', 'coast', 'gallery']);
      expect(() => definition.sideQuests.clear(), throwsUnsupportedError);
      expect(
        () => definition.sideQuests.first.choices.clear(),
        throwsUnsupportedError,
      );
      expect(() => choice.route.clear(), throwsUnsupportedError);
      final coords = <double>[1, 2, 3], route = ['coast'];
      final object = VrlzExpeditionObject(
        id: 'o',
        label: 'O',
        kind: 'collect',
        position: coords,
      );
      final copy = VrlzExpeditionChoice(
        id: 'c',
        label: 'C',
        dialogue: 'D',
        discovery: 'Found',
        route: route,
        object: object,
      );
      route.clear();
      coords.clear();
      expect(copy.route, ['coast']);
      expect(copy.object.position, [1, 2, 3]);
    },
  );

  test(
    'unlock, proximity, explicit selection and one pending quest are enforced',
    () async {
      final c = VrlzExpeditionController(
        definition: _definition(),
        store: ExpeditionMemoryStore(),
      );
      await c.restore();
      expect(c.availableSideQuests, isEmpty);
      expect(c.focusSideQuest('side_a'), isFalse);
      expect(c.chooseSideQuest('side_a', 'scenic', 'garden', _giver), isFalse);
      await _unlock(c);
      expect(c.availableSideQuests.map((q) => q.id), ['side_a', 'side_b']);
      expect(c.focusSideQuest('unknown'), isFalse);
      expect(c.focusSideQuest('side_a'), isTrue);
      expect(c.focusedSideProgress, isNull);
      expect(c.sideDestination, 'garden');
      expect(c.chooseSideQuest('side_a', 'unknown', 'garden', _giver), isFalse);
      expect(c.chooseSideQuest('side_a', 'scenic', 'gallery', _giver), isFalse);
      expect(c.chooseSideQuest('side_a', 'scenic', 'garden', _object), isFalse);
      expect(
        c.chooseSideQuest('side_a', 'scenic', 'garden', [double.nan, 0, 0]),
        isFalse,
      );
      expect(c.chooseSideQuest('side_a', 'scenic', 'garden', _giver), isTrue);
      expect(c.focusedSideChoice?.id, 'scenic');
      expect(c.pendingSideQuestId, 'side_a');
      expect(c.sideDestination, 'ridge');
      expect(c.chooseSideQuest('side_a', 'direct', 'garden', _giver), isFalse);
      expect(c.focusSideQuest('side_b'), isFalse);
      c.visit('gallery');
      expect(c.chooseSideQuest('side_b', 'scenic', 'gallery', _giver), isFalse);
      expect(c.focusSideQuest(null), isTrue);
      expect(c.focusedSideQuest, isNull);
      expect(c.pendingSideQuestId, 'side_a');
      expect(c.focusSideQuest('side_a'), isTrue);
      expect(c.focusedSideChoice?.id, 'scenic');
      expect(await c.flush(), isTrue);
      c.dispose();
    },
  );

  test(
    'pre-choice stamps do not credit a route and repeat visits advance only its next stop',
    () async {
      final c = VrlzExpeditionController(
        definition: _definition(),
        store: ExpeditionMemoryStore(),
      );
      await c.restore();
      await _unlock(c);
      for (final world in ['ridge', 'coast', 'gallery']) {
        c.visit(world);
      }
      c.chooseSideQuest('side_a', 'scenic', 'garden', _giver);
      expect(c.focusedSideProgress?.visitedStops, 0);
      expect(c.visit('gallery'), isFalse);
      expect(c.canInteractSideQuest('side_a', 'gallery', _object), isFalse);
      expect(c.visit('ridge'), isTrue);
      expect(c.focusedSideProgress?.visitedStops, 1);
      expect(c.visit('ridge'), isFalse);
      expect(c.visit('gallery'), isFalse);
      expect(c.visit('coast'), isTrue);
      expect(c.visit('gallery'), isTrue);
      expect(c.sideDestination, 'gallery');
      expect(c.interactSideQuest('side_a', 'coast', _object), isFalse);
      expect(c.interactSideQuest('side_a', 'gallery', _giver), isFalse);
      expect(c.completeSideQuest('side_a', 'garden', _giver), isFalse);
      expect(c.interactSideQuest('side_a', 'gallery', _object), isTrue);
      expect(c.sideDestination, 'garden');
      expect(c.interactSideQuest('side_a', 'gallery', _object), isFalse);
      expect(c.completeSideQuest('side_a', 'gallery', _giver), isFalse);
      expect(c.completeSideQuest('side_a', 'garden', _object), isFalse);
      expect(c.completeSideQuest('side_a', 'garden', _giver), isTrue);
      expect(c.pendingSideQuestId, isNull);
      expect(c.focusedSideQuestId, isNull);
      expect(c.sideProgress['side_a']!.completedAt!.isUtc, isTrue);
      expect(c.availableSideQuests.map((q) => q.id), ['side_b']);
      expect(c.chooseSideQuest('side_a', 'direct', 'garden', _giver), isFalse);
      expect(c.focusSideQuest('side_a'), isFalse);
      expect(c.rewardIds, isEmpty);
      expect(() => c.sideProgress.clear(), throwsUnsupportedError);
      expect(await c.flush(), isTrue);
      c.dispose();
    },
  );

  test(
    'each checkpoint, collection and return survives restart while main pending stays intact',
    () async {
      final store = ExpeditionMemoryStore();
      var c = VrlzExpeditionController(definition: _definition(), store: store);
      await c.restore();
      await _unlock(c);
      c.visit('gallery');
      c.accept('second', 'gallery', _giver);
      c.chooseSideQuest('side_a', 'scenic', 'garden', _giver);
      Future<void> reload() async {
        expect(await c.flush(), isTrue);
        c.dispose();
        c = VrlzExpeditionController(definition: _definition(), store: store);
        await c.restore();
        expect(c.acceptedMissionId, 'second');
        expect(c.objectiveCollected, isFalse);
      }

      await reload();
      expect(c.sideDestination, 'ridge');
      c.visit('ridge');
      await reload();
      expect(c.focusedSideProgress?.visitedStops, 1);
      expect(c.sideDestination, 'coast');
      c.visit('coast');
      await reload();
      expect(c.focusedSideProgress?.visitedStops, 2);
      expect(c.sideDestination, 'gallery');
      c.visit('gallery');
      await reload();
      expect(c.focusedSideProgress?.visitedStops, 3);
      c.interactSideQuest('side_a', 'gallery', _object);
      await reload();
      expect(c.focusedSideProgress?.collected, isTrue);
      expect(c.sideDestination, 'garden');
      c.focusSideQuest(null);
      await reload();
      expect(c.focusedSideQuest, isNull);
      expect(c.pendingSideQuestId, 'side_a');
      c.focusSideQuest('side_a');
      c.completeSideQuest('side_a', 'garden', _giver);
      await reload();
      expect(c.sideProgress['side_a']?.choiceId, 'scenic');
      expect(c.sideProgress['side_a']?.completedAt, isNotNull);
      expect(c.focusedSideQuest, isNull);
      expect(c.pendingSideQuestId, isNull);
      expect(c.interact('second', 'gallery', _object), isTrue);
      expect(c.complete('second', 'gallery', _giver), isTrue);
      expect(await c.flush(), isTrue);
      c.dispose();
    },
  );

  test(
    'second alternative has its own destinations and cannot be rerolled after return',
    () async {
      final c = VrlzExpeditionController(
        definition: _definition(),
        store: ExpeditionMemoryStore(),
      );
      await c.restore();
      await _unlock(c);
      c.chooseSideQuest('side_a', 'direct', 'garden', _giver);
      expect(c.sideDestination, 'forest');
      c.visit('forest');
      expect(c.sideDestination, 'market');
      c.visit('market');
      expect(c.interactSideQuest('side_a', 'gallery', _object), isFalse);
      expect(c.interactSideQuest('side_a', 'market', _object), isTrue);
      expect(c.completeSideQuest('side_a', 'garden', _giver), isTrue);
      expect(c.chooseSideQuest('side_a', 'scenic', 'garden', _giver), isFalse);
      expect(c.sideProgress['side_a']?.choiceId, 'direct');
      c.visit('gallery');
      expect(c.chooseSideQuest('side_b', 'scenic', 'gallery', _giver), isTrue);
      expect(await c.flush(), isTrue);
      c.dispose();
    },
  );

  test(
    'legacy snapshots unlock side stories without writes or losing completed IDs',
    () async {
      final store = ExpeditionMemoryStore();
      final legacy = VrlzExpeditionController(
        definition: expeditionFixture(),
        store: store,
      );
      await legacy.restore();
      await _unlock(legacy);
      final previous = Uint8List.fromList(store.bytes!);
      legacy.dispose();
      final enriched = VrlzExpeditionController(
        definition: _definition(),
        store: store,
      );
      await enriched.restore();
      expect(enriched.completedMissions.keys, ['first']);
      expect(enriched.availableSideQuests.length, 2);
      expect(enriched.sideProgress, isEmpty);
      expect(await enriched.flush(), isTrue);
      expect(store.bytes, previous);
      enriched.dispose();
    },
  );

  test(
    'write failure and concurrent updates keep the selected route recoverable',
    () async {
      final store = ExpeditionMemoryStore();
      final c = VrlzExpeditionController(
        definition: _definition(),
        store: store,
      );
      await c.restore();
      await _unlock(c);
      final gate = Completer<void>();
      store.nextWriteGate = gate;
      c.chooseSideQuest('side_a', 'scenic', 'garden', _giver);
      final saving = c.flush();
      c.visit('ridge');
      c.visit('coast');
      c.visit('gallery');
      c.interactSideQuest('side_a', 'gallery', _object);
      c.focusSideQuest(null);
      expect(identical(saving, c.flush()), isTrue);
      gate.complete();
      expect(await saving, isTrue);
      expect(store.maxActiveWrites, 1);
      store.failWrites = 1;
      c.completeSideQuest('side_a', 'garden', _giver);
      expect(await c.flush(), isFalse);
      final durable = VrlzExpeditionController(
        definition: _definition(),
        store: store,
      );
      await durable.restore();
      expect(durable.pendingSideQuestId, 'side_a');
      expect(durable.sideProgress['side_a']?.collected, isTrue);
      expect(durable.focusedSideQuestId, isNull);
      expect(await c.flush(), isTrue);
      final reloaded = VrlzExpeditionController(
        definition: _definition(),
        store: store,
      );
      await reloaded.restore();
      expect(reloaded.sideProgress['side_a']?.completedAt, isNotNull);
      c.dispose();
      durable.dispose();
      reloaded.dispose();
    },
  );

  final invalidDefinitions = <String, void Function(Map<String, dynamic>)>{
    'null side quests': (j) => j['sideQuests'] = null,
    'too many': (j) =>
        j['sideQuests'] = [for (var i = 0; i < 25; i++) j['sideQuests'][0]],
    'duplicate side ID': (j) => j['sideQuests'][1]['id'] = 'side_a',
    'main ID collision': (j) => j['sideQuests'][0]['id'] = 'first',
    'unknown unlock': (j) => j['sideQuests'][0]['afterMissionId'] = 'unknown',
    'unknown origin': (j) => j['sideQuests'][0]['world'] = 'unknown',
    'one choice': (j) => j['sideQuests'][0]['choices'].removeLast(),
    'duplicate choice ID': (j) =>
        j['sideQuests'][0]['choices'][1]['id'] = 'scenic',
    'empty route': (j) => j['sideQuests'][0]['choices'][0]['route'] = [],
    'long route': (j) => j['sideQuests'][0]['choices'][0]['route'] = [
      'ridge',
      'coast',
      'gallery',
      'market',
    ],
    'duplicate stop': (j) =>
        j['sideQuests'][0]['choices'][0]['route'] = ['ridge', 'ridge'],
    'origin in route': (j) =>
        j['sideQuests'][0]['choices'][0]['route'] = ['garden'],
    'unknown stop': (j) =>
        j['sideQuests'][0]['choices'][0]['route'] = ['unknown'],
    'nonstrings route': (j) => j['sideQuests'][0]['choices'][0]['route'] = [4],
    'unsafe choice ID': (j) =>
        j['sideQuests'][0]['choices'][0]['id'] = '../bad',
    'unknown choice field': (j) =>
        j['sideQuests'][0]['choices'][0]['code'] = 'run',
    'unknown side field': (j) =>
        j['sideQuests'][0]['url'] = 'https://invalid.test',
    'missing discovery': (j) =>
        j['sideQuests'][0]['choices'][0].remove('discovery'),
  };
  for (final entry in invalidDefinitions.entries) {
    test('side definition rejects ${entry.key}', () {
      final json = _definition().toJson();
      entry.value(json);
      expect(
        () => VrlzExpeditionDefinition.fromJson(json),
        throwsFormatException,
      );
    });
  }

  final invalidSnapshots = <String, void Function(Map<String, dynamic>)>{
    'null progress': (j) => j['sideQuests'] = null,
    'empty progress': (j) => j['sideQuests'] = {},
    'unknown quest': (j) => j['sideQuests'] = {'unknown': _stage()},
    'locked quest': (j) => j['completedMissions'] = {},
    'origin unvisited': (j) {
      j['sideQuests'] = {'side_b': _stage(stops: 0)};
      j.remove('focusedSideQuestId');
      j['visitedWorlds'].remove('gallery');
    },
    'unknown choice': (j) => j['sideQuests']['side_a']['choiceId'] = 'unknown',
    'negative stop': (j) => j['sideQuests']['side_a']['visitedStops'] = -1,
    'overflow stop': (j) => j['sideQuests']['side_a']['visitedStops'] = 4,
    'floating stop': (j) => j['sideQuests']['side_a']['visitedStops'] = 1.0,
    'collected before last stop': (j) =>
        j['sideQuests']['side_a']['collected'] = true,
    'unknown prefix visit': (j) => j['visitedWorlds'].remove('ridge'),
    'nonbool collected': (j) => j['sideQuests']['side_a']['collected'] = 1,
    'unknown stage field': (j) => j['sideQuests']['side_a']['script'] = 'run',
    'missing choice': (j) => j['sideQuests']['side_a'].remove('choiceId'),
    'completed without object': (j) =>
        j['sideQuests']['side_a']['completedAt'] = _time,
    'completed before unlock': (j) {
      j['sideQuests']['side_a'] = _stage(stops: 3, collected: true)
        ..['completedAt'] = '2025-01-01T00:00:00.000Z';
    },
    'completed before visit': (j) {
      j['sideQuests']['side_a'] = _stage(stops: 3, collected: true)
        ..['completedAt'] = _time;
      j['visitedWorlds']['coast'] = '2027-01-01T00:00:00.000Z';
    },
    'completed with missing route visit': (j) {
      j['sideQuests']['side_a'] = _stage(stops: 3, collected: true)
        ..['completedAt'] = _time;
      j.remove('focusedSideQuestId');
      j['visitedWorlds'].remove('coast');
    },
    'noncanonical date': (j) {
      j['sideQuests']['side_a'] = _stage(stops: 3, collected: true)
        ..['completedAt'] = '2026-10-26';
    },
    'two pending quests': (j) => j['sideQuests']['side_b'] = _stage(stops: 0),
    'null focus': (j) => j['focusedSideQuestId'] = null,
    'unknown focus': (j) => j['focusedSideQuestId'] = 'unknown',
    'other focus while pending': (j) => j['focusedSideQuestId'] = 'side_b',
    'completed focus': (j) =>
        j['sideQuests']['side_a'] = _stage(stops: 3, collected: true)
          ..['completedAt'] = _time,
  };
  for (final entry in invalidSnapshots.entries) {
    test(
      'restore rejects ${entry.key} atomically without overwriting',
      () async {
        final snapshot = _snapshot();
        entry.value(snapshot);
        final bytes = Uint8List.fromList(utf8.encode(jsonEncode(snapshot)));
        final store = ExpeditionMemoryStore()..bytes = bytes;
        final c = VrlzExpeditionController(
          definition: _definition(),
          store: store,
        );
        await expectLater(c.restore(), throwsFormatException);
        expect(c.ready, isFalse);
        expect(c.completedMissions, isEmpty);
        expect(c.sideProgress, isEmpty);
        expect(c.focusedSideQuestId, isNull);
        expect(await c.flush(), isFalse);
        expect(store.writes, 0);
        expect(store.bytes, bytes);
        c.dispose();
      },
    );
  }
}

Future<void> _unlock(VrlzExpeditionController c) async {
  c.visit('garden');
  expect(c.complete('first', 'garden', [1, 1.6, 2]), isTrue);
  expect(await c.flush(), isTrue);
}

VrlzExpeditionDefinition _definition() {
  final json = expeditionFixture().toJson();
  (json['worlds'] as Map<String, String>).addAll({
    'ridge': 'Ridge',
    'coast': 'Coast',
    'forest': 'Forest',
    'market': 'Market',
  });
  Map<String, dynamic> giver() => {
    'id': 'guide',
    'name': 'Guide',
    'dialogue': 'Choose your route',
    'species': 'robot',
    'position': _giver.toList(),
    'radius': 2.5,
  };
  Map<String, dynamic> object() => {
    'id': 'object',
    'label': 'Record',
    'kind': 'collect',
    'position': _object.toList(),
    'radius': 2.5,
  };
  json['missions'][1]['giver'] = giver();
  json['missions'][1]['object'] = object();
  Map<String, dynamic> choice(String id, List<String> route) => {
    'id': id,
    'label': id,
    'dialogue': 'Travel deliberately',
    'discovery': 'A remembered route',
    'route': route,
    'object': object(),
  };
  json['sideQuests'] = [
    {
      'id': 'side_a',
      'title': 'Alternative paths',
      'afterMissionId': 'first',
      'world': 'garden',
      'giver': giver(),
      'choices': [
        choice('scenic', ['ridge', 'coast', 'gallery']),
        choice('direct', ['forest', 'market']),
      ],
    },
    {
      'id': 'side_b',
      'title': 'A second story',
      'afterMissionId': 'first',
      'world': 'gallery',
      'giver': giver(),
      'choices': [
        choice('scenic', ['coast']),
        choice('direct', ['market']),
      ],
    },
  ];
  return VrlzExpeditionDefinition.fromJson(json);
}

Map<String, dynamic> _stage({int stops = 1, bool collected = false}) => {
  'choiceId': 'scenic',
  'visitedStops': stops,
  'collected': collected,
};
Map<String, dynamic> _snapshot() => {
  'schema': 1,
  'id': 'openneom.expedition',
  'experienceId': 'openneom.worlds',
  'revision': 1,
  'visitedWorlds': {
    'garden': _time,
    'gallery': _time,
    'ridge': _time,
    'coast': _time,
  },
  'completedMissions': {'first': _time},
  'sideQuests': {'side_a': _stage()},
  'focusedSideQuestId': 'side_a',
};
