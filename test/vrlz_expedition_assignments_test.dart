import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_apps/vrlizate_apps_expedition.dart';

import 'support/vrlz_expedition_fixture.dart';

const _giver = <double>[0, 1.6, 0];
const _object = <double>[12, 1.6, 0];

void main() {
  test(
    'only an explicit ordered conversation, object and return earn a reward',
    () async {
      final store = ExpeditionMemoryStore();
      final c = VrlzExpeditionController(
        definition: _definition(),
        store: store,
      );
      await c.restore();
      expect(c.accept('first', 'garden', _giver), isFalse);
      expect(c.visit('garden'), isTrue);
      expect(c.rewardIds, isEmpty);
      expect(c.acceptedMissionId, isNull);
      expect(c.interact('first', 'garden', _object), isFalse);
      expect(c.complete('first', 'garden', _giver), isFalse);
      expect(c.accept('second', 'gallery', _giver), isFalse);
      expect(c.accept('first', 'gallery', _giver), isFalse);
      expect(c.accept('first', 'garden', _object), isFalse);
      expect(c.accept('first', 'garden', _giver), isTrue);
      expect(c.acceptedMissionId, 'first');
      expect(c.objectiveCollected, isFalse);
      expect(c.accept('first', 'garden', _giver), isFalse);
      expect(c.interact('first', 'garden', _giver), isFalse);
      expect(c.interact('first', 'gallery', _object), isFalse);
      expect(c.complete('first', 'garden', _giver), isFalse);
      expect(c.interact('first', 'garden', _object), isTrue);
      expect(c.objectiveCollected, isTrue);
      expect(c.interact('first', 'garden', _object), isFalse);
      expect(c.complete('first', 'garden', _object), isFalse);
      expect(c.complete('first', 'garden', _giver), isTrue);
      expect(c.rewardIds, {'expedition_canopy'});
      expect(() => c.rewardIds.clear(), throwsUnsupportedError);
      expect(c.acceptedMissionId, isNull);
      expect(c.objectiveCollected, isFalse);
      expect(c.nextMission?.id, 'second');
      expect(c.complete('first', 'garden', _giver), isFalse);
      expect(await c.flush(), isTrue);
      c.dispose();
    },
  );

  test(
    'all steps reject nonfinite, malformed and out-of-range positions',
    () async {
      final c = VrlzExpeditionController(
        definition: _definition(),
        store: ExpeditionMemoryStore(),
      );
      await c.restore();
      c.visit('garden');
      final bad = <List<double>>[
        [double.nan, 1.6, 0],
        [double.infinity, 1.6, 0],
        [1e6 + 1, 1.6, 0],
        [],
        [0, 1.6],
        [0, 1.6, 0, 0],
        [0, 10, 0],
      ];
      for (final position in bad) {
        expect(c.canAccept('first', 'garden', position), isFalse);
        expect(c.accept('first', 'garden', position), isFalse);
      }
      expect(c.accept('first', 'garden', [2.5, 1.6, 0]), isTrue);
      for (final position in bad) {
        expect(c.interact('first', 'garden', position), isFalse);
      }
      expect(c.interact('first', 'garden', [14.5, 1.6, 0]), isTrue);
      for (final position in bad) {
        expect(c.complete('first', 'garden', position), isFalse);
      }
      expect(c.complete('first', 'garden', [2.5, 1.6, 0]), isTrue);
      expect(await c.flush(), isTrue);
      c.dispose();
    },
  );

  for (final collected in [false, true]) {
    test(
      'pending ${collected ? 'collected' : 'accepted'} stage survives reload',
      () async {
        final store = ExpeditionMemoryStore();
        final c = VrlzExpeditionController(
          definition: _definition(),
          store: store,
        );
        await c.restore();
        c.visit('garden');
        c.accept('first', 'garden', _giver);
        if (collected) c.interact('first', 'garden', _object);
        expect(await c.flush(), isTrue);
        final json =
            jsonDecode(utf8.decode(store.bytes!)) as Map<String, dynamic>;
        expect(json['schema'], 1);
        expect(json['pendingMission'], {
          'missionId': 'first',
          'stage': collected ? 'collected' : 'accepted',
        });
        expect(json.containsKey('rewardIds'), isFalse);
        c.dispose();
        final reloaded = VrlzExpeditionController(
          definition: _definition(),
          store: store,
        );
        await reloaded.restore();
        expect(reloaded.acceptedMissionId, 'first');
        expect(reloaded.objectiveCollected, collected);
        expect(reloaded.rewardIds, isEmpty);
        expect(reloaded.canComplete('first', 'garden', _giver), collected);
        expect(reloaded.canInteract('first', 'garden', _object), !collected);
        reloaded.dispose();
      },
    );
  }

  test(
    'old completed IDs survive enriched revision1 and derive rewards once',
    () async {
      final store = ExpeditionMemoryStore();
      final legacy = VrlzExpeditionController(
        definition: expeditionFixture(),
        store: store,
      );
      await legacy.restore();
      legacy.visit('garden');
      legacy.complete('first', 'garden', [1, 1.6, 2]);
      expect(await legacy.flush(), isTrue);
      final old = Uint8List.fromList(store.bytes!);
      expect(
        jsonDecode(utf8.decode(old)).containsKey('pendingMission'),
        isFalse,
      );
      legacy.dispose();
      final enriched = VrlzExpeditionController(
        definition: _definition(),
        store: store,
      );
      await enriched.restore();
      expect(enriched.definition.revision, 1);
      expect(enriched.completedMissions.keys, ['first']);
      expect(enriched.rewardIds, {'expedition_canopy'});
      expect(enriched.acceptedMissionId, isNull);
      expect(enriched.nextMission?.id, 'second');
      expect(enriched.accept('first', 'garden', _giver), isFalse);
      expect(await enriched.flush(), isTrue);
      expect(store.bytes, old);
      enriched.visit('gallery');
      enriched.accept('second', 'gallery', _giver);
      enriched.interact('second', 'gallery', _object);
      enriched.complete('second', 'gallery', _giver);
      expect(enriched.rewardIds, {
        'expedition_canopy',
      }); // shared ID never duplicates.
      expect(await enriched.flush(), isTrue);
      enriched.dispose();
    },
  );

  test(
    'visit and repeated interactions never grant or enqueue duplicate rewards',
    () async {
      final store = ExpeditionMemoryStore();
      final c = VrlzExpeditionController(
        definition: _definition(),
        store: store,
      );
      await c.restore();
      c.visit('garden');
      c.visit('gallery');
      expect(c.rewardIds, isEmpty);
      expect(await c.flush(), isTrue);
      var changes = 0;
      c.addListener(() => changes++);
      c.accept('first', 'garden', _giver);
      c.interact('first', 'garden', _object);
      c.complete('first', 'garden', _giver);
      expect(await c.flush(), isTrue);
      final writes = store.writes;
      for (var frame = 0; frame < 1000; frame++) {
        expect(c.accept('first', 'garden', _giver), isFalse);
        expect(c.interact('first', 'garden', _object), isFalse);
        expect(c.complete('first', 'garden', _giver), isFalse);
      }
      expect(changes, 3);
      expect(await c.flush(), isTrue);
      expect(store.writes, writes);
      c.dispose();
    },
  );

  test(
    'pending and turn-in retain dirty state through write failures',
    () async {
      final store = ExpeditionMemoryStore();
      final c = VrlzExpeditionController(
        definition: _definition(),
        store: store,
      );
      await c.restore();
      c.visit('garden');
      expect(await c.flush(), isTrue);
      store.failWrites = 1;
      c.accept('first', 'garden', _giver);
      c.interact('first', 'garden', _object);
      expect(await c.flush(), isFalse);
      expect(c.acceptedMissionId, 'first');
      expect(c.objectiveCollected, isTrue);
      expect(c.rewardIds, isEmpty);
      expect(await c.flush(), isTrue);
      store.failWrites = 1;
      c.complete('first', 'garden', _giver);
      expect(await c.flush(), isFalse);
      final durable = VrlzExpeditionController(
        definition: _definition(),
        store: store,
      );
      await durable.restore();
      expect(durable.completedMissions, isEmpty);
      expect(durable.objectiveCollected, isTrue);
      expect(durable.rewardIds, isEmpty);
      expect(await c.flush(), isTrue);
      final saved = VrlzExpeditionController(
        definition: _definition(),
        store: store,
      );
      await saved.restore();
      expect(saved.rewardIds, {'expedition_canopy'});
      expect(saved.acceptedMissionId, isNull);
      c.dispose();
      durable.dispose();
      saved.dispose();
    },
  );

  test(
    'steps arriving during a blocked write serialize the latest turn-in',
    () async {
      final store = ExpeditionMemoryStore();
      final c = VrlzExpeditionController(
        definition: _definition(),
        store: store,
      );
      await c.restore();
      c.visit('garden');
      expect(await c.flush(), isTrue);
      final gate = Completer<void>();
      store.nextWriteGate = gate;
      c.accept('first', 'garden', _giver);
      final saving = c.flush();
      c.interact('first', 'garden', _object);
      c.complete('first', 'garden', _giver);
      expect(identical(saving, c.flush()), isTrue);
      gate.complete();
      expect(await saving, isTrue);
      expect(store.maxActiveWrites, 1);
      expect(
        store.writes,
        3,
      ); // initial visit, accepted stage, final completion.
      final finalSnapshot = jsonDecode(utf8.decode(store.bytes!));
      expect(finalSnapshot.containsKey('pendingMission'), isFalse);
      expect(finalSnapshot['completedMissions'].keys, ['first']);
      c.dispose();
    },
  );

  test(
    'giver and object JSON is defensive and uses a closed data-only schema',
    () {
      final definition = _definition();
      final json = definition.toJson();
      expect(VrlzExpeditionDefinition.fromJson(json).toJson(), json);
      json['missions'][0]['giver']['position'][0] = 999.0;
      json['missions'][0]['object']['position'][0] = 999.0;
      expect(definition.missions.first.giver!.position, _giver);
      expect(definition.missions.first.object!.position, _object);
      expect(
        () => definition.missions.first.giver!.position.clear(),
        throwsUnsupportedError,
      );
      expect(
        () => definition.missions.first.object!.position.clear(),
        throwsUnsupportedError,
      );
      final position = <double>[0, 1.6, 0];
      final giver = VrlzExpeditionGiver(
        id: 'g',
        name: 'Robot',
        dialogue: 'Hola',
        species: 'robot',
        position: position,
      );
      position[0] = 100;
      expect(giver.position, _giver);
      expect(
        () => VrlzExpeditionMission(
          id: 'm',
          world: 'garden',
          title: 'T',
          instruction: 'I',
          discovery: 'D',
          position: _giver,
          giver: giver,
        ),
        throwsArgumentError,
      );
    },
  );

  final badDefinitions = <String, void Function(Map<String, dynamic>)>{
    'giver without object': (m) => m.remove('object'),
    'object without giver': (m) => m.remove('giver'),
    'null giver': (m) => m['giver'] = null,
    'unknown giver field': (m) => m['giver']['script'] = 'run()',
    'missing giver field': (m) => m['giver'].remove('species'),
    'unsafe species': (m) => m['giver']['species'] = '../robot',
    'empty dialogue': (m) => m['giver']['dialogue'] = '',
    'long dialogue': (m) => m['giver']['dialogue'] = 'x' * 1025,
    'giver coordinate': (m) => m['giver']['position'] = [0, double.nan, 0],
    'giver radius': (m) => m['giver']['radius'] = 11,
    'unknown object field': (m) => m['object']['url'] = 'https://invalid.test',
    'missing object field': (m) => m['object'].remove('kind'),
    'unsupported kind': (m) => m['object']['kind'] = 'execute',
    'unsafe object ID': (m) => m['object']['id'] = '../object',
    'object position': (m) => m['object']['position'] = [0, 0],
    'object radius': (m) => m['object']['radius'] = -.1,
    'null reward': (m) => m['rewardId'] = null,
    'unsafe reward': (m) => m['rewardId'] = 'reward/path',
  };
  for (final entry in badDefinitions.entries) {
    test('assignment definition rejects ${entry.key}', () {
      final json = _definition().toJson();
      entry.value(json['missions'][0] as Map<String, dynamic>);
      expect(
        () => VrlzExpeditionDefinition.fromJson(json),
        throwsFormatException,
      );
    });
  }

  final badPending = <String, Object?>{
    'null': null,
    'array': [],
    'unknown field': {
      'missionId': 'first',
      'stage': 'accepted',
      'reward': true,
    },
    'missing stage': {'missionId': 'first'},
    'unknown stage': {'missionId': 'first', 'stage': 'complete'},
    'wrong ID': {'missionId': 'second', 'stage': 'accepted'},
    'nonstring ID': {'missionId': 1, 'stage': 'accepted'},
  };
  for (final entry in badPending.entries) {
    test(
      'pending progress rejects ${entry.key} without overwriting source',
      () async {
        final store = ExpeditionMemoryStore()..bytes = _progress(entry.value);
        final original = Uint8List.fromList(store.bytes!);
        final c = VrlzExpeditionController(
          definition: _definition(),
          store: store,
        );
        await expectLater(c.restore(), throwsFormatException);
        expect(c.ready, isFalse);
        expect(c.acceptedMissionId, isNull);
        expect(c.completedMissions, isEmpty);
        expect(c.rewardIds, isEmpty);
        expect(await c.flush(), isFalse);
        expect(store.writes, 0);
        expect(store.bytes, original);
        c.dispose();
      },
    );
  }

  test(
    'pending cannot attach to legacy, completed, unvisited or finished missions',
    () async {
      for (final kind in ['legacy', 'completed', 'unvisited', 'finished']) {
        final map =
            jsonDecode(
                  utf8.decode(
                    _progress({'missionId': 'first', 'stage': 'accepted'}),
                  ),
                )
                as Map<String, dynamic>;
        if (kind == 'completed') map['completedMissions'] = {'first': _time};
        if (kind == 'unvisited') map['visitedWorlds'] = {};
        if (kind == 'finished') {
          map['visitedWorlds'] = {'garden': _time, 'gallery': _time};
          map['completedMissions'] = {
            'first': _time,
            'second': _time,
            'third': _time,
          };
        }
        final store = ExpeditionMemoryStore()
          ..bytes = Uint8List.fromList(utf8.encode(jsonEncode(map)));
        final c = VrlzExpeditionController(
          definition: kind == 'legacy' ? expeditionFixture() : _definition(),
          store: store,
        );
        await expectLater(c.restore(), throwsFormatException, reason: kind);
        expect(store.writes, 0);
        c.dispose();
      }
    },
  );
}

VrlzExpeditionDefinition _definition() {
  final json = expeditionFixture().toJson();
  for (var index = 0; index < 3; index++) {
    final mission = json['missions'][index] as Map<String, dynamic>;
    mission['giver'] = {
      'id': 'guide-$index',
      'name': 'Guía $index',
      'dialogue': '¿Puedes recuperar la forma?',
      'species': 'robot',
      'position': _giver.toList(),
      'radius': 2.5,
    };
    mission['object'] = {
      'id': 'object-$index',
      'label': 'Forma $index',
      'kind': ['collect', 'examine', 'activate'][index],
      'position': _object.toList(),
      'radius': 2.5,
    };
    mission['rewardId'] = index < 2 ? 'expedition_canopy' : 'expedition_aurora';
  }
  return VrlzExpeditionDefinition.fromJson(json);
}

const _time = '2026-10-26T00:00:00.000Z';
Uint8List _progress(Object? pending) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'schema': 1,
      'id': 'openneom.expedition',
      'experienceId': 'openneom.worlds',
      'revision': 1,
      'visitedWorlds': {'garden': _time},
      'completedMissions': <String, String>{},
      'pendingMission': pending,
    }),
  ),
);
