import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_apps/vrlizate_apps_expedition.dart';

import 'support/vrlz_expedition_fixture.dart';

const _giver = <double>[0, 1.6, 0], _object = <double>[12, 1.6, 0];
const _t0 = '2026-10-26T00:00:00.000Z',
    _t1 = '2026-10-26T00:00:01.000Z',
    _t2 = '2026-10-26T00:00:02.000Z',
    _t3 = '2026-10-26T00:00:03.000Z';

void main() {
  test('requirements and variants round trip as immutable optional data', () {
    final definition = _definition();
    expect(
      VrlzExpeditionDefinition.fromJson(definition.toJson()).toJson(),
      definition.toJson(),
    );
    final old = _definition(enriched: false).toJson();
    expect(
      (old['sideQuests'] as List).every(
        (q) => !q.containsKey('requires') && !q.containsKey('dialogueVariants'),
      ),
      isTrue,
    );
    final choices = ['sun'], requirements = <VrlzExpeditionStoryRequirement>[];
    final requirement = VrlzExpeditionStoryRequirement(
      questId: 'a',
      choiceIds: choices,
    );
    requirements.add(requirement);
    final variant = VrlzExpeditionDialogueVariant(
      requires: requirements,
      dialogue: 'Remembered',
    );
    choices.clear();
    requirements.clear();
    expect(requirement.choiceIds, ['sun']);
    expect(variant.requires.length, 1);
    expect(() => requirement.choiceIds.clear(), throwsUnsupportedError);
    expect(() => variant.requires.clear(), throwsUnsupportedError);
    final side = definition.sideQuests[1];
    expect(() => side.requires.clear(), throwsUnsupportedError);
    expect(() => side.dialogueVariants.clear(), throwsUnsupportedError);
    final json = definition.toJson();
    json['sideQuests'][1]['requires'][0]['choiceIds'][0] = 'changed';
    expect(side.requires.first.choiceIds, ['sun', 'moon']);
  });

  test(
    'unlock requires delivery; acceptance and collection do not count',
    () async {
      final c = await _open();
      final a = _quest(c, 'a'), b = _quest(c, 'b');
      expect(c.isSideQuestUnlocked(a), isFalse);
      await _unlock(c);
      expect(c.isSideQuestUnlocked(a), isTrue);
      expect(c.isSideQuestUnlocked(b), isFalse);
      expect(c.focusSideQuest('b'), isFalse);
      expect(c.chooseSideQuest('b', 'sun', 'garden', _giver), isFalse);
      c.chooseSideQuest('a', 'sun', 'garden', _giver);
      expect(c.isSideQuestUnlocked(b), isFalse);
      c.visit('gallery');
      c.interactSideQuest('a', 'gallery', _object);
      expect(c.isSideQuestUnlocked(b), isFalse);
      c.completeSideQuest('a', 'garden', _giver);
      expect(c.isSideQuestUnlocked(b), isTrue);
      expect(c.sideQuestDialogue(b), 'The sun route was delivered.');
      expect(c.availableSideQuests.map((q) => q.id), ['b']);
      expect(await c.flush(), isTrue);
      c.dispose();
    },
  );

  test(
    'OR choices unlock both branches while AND requirements stay conjunctive',
    () async {
      for (final selected in ['sun', 'moon']) {
        final c = await _open();
        await _unlock(c);
        await _deliver(c, 'a', selected);
        expect(c.isSideQuestUnlocked(_quest(c, 'b')), isTrue);
        expect(c.isSideQuestUnlocked(_quest(c, 'c')), isFalse);
        expect(c.isSideQuestUnlocked(_quest(c, 'd')), selected == 'moon');
        expect(
          c.sideQuestDialogue(_quest(c, 'b')),
          selected == 'sun'
              ? 'The sun route was delivered.'
              : 'A route was delivered.',
        );
        await _deliver(c, 'b', 'moon');
        expect(c.isSideQuestUnlocked(_quest(c, 'c')), selected == 'sun');
        expect(c.focusSideQuest('c'), selected == 'sun');
        expect(await c.flush(), isTrue);
        c.dispose();
      }
    },
  );

  test(
    'dialogue is canonical, first-match and derived from delivered history',
    () async {
      final c = await _open();
      await _unlock(c);
      final b = _quest(c, 'b');
      expect(c.sideQuestDialogue(b), 'Default b');
      await _deliver(c, 'a', 'sun');
      expect(
        c.sideQuestDialogue(b),
        'The sun route was delivered.',
      ); // broad second also matches.
      final foreignJson = b.toJson();
      foreignJson['giver']['dialogue'] = 'Forged default';
      foreignJson['dialogueVariants'] = [];
      expect(
        c.sideQuestDialogue(VrlzExpeditionSideQuest.fromJson(foreignJson)),
        'The sun route was delivered.',
      );
      foreignJson['id'] = 'unknown';
      final unknown = VrlzExpeditionSideQuest.fromJson(foreignJson);
      expect(c.isSideQuestUnlocked(unknown), isFalse);
      expect(() => c.sideQuestDialogue(unknown), throwsArgumentError);
      expect(await c.flush(), isTrue);
      c.dispose();
    },
  );

  test(
    'self and cross dialogue references do not form unlock cycles',
    () async {
      final json = _definition().toJson();
      json['sideQuests'][0]['dialogueVariants'] = [
        {
          'requires': [
            _require('b', ['moon']),
          ],
          'dialogue': 'B is remembered.',
        },
      ];
      final definition = VrlzExpeditionDefinition.fromJson(json);
      final c = VrlzExpeditionController(
        definition: definition,
        store: ExpeditionMemoryStore(),
      );
      await c.restore();
      await _unlock(c);
      await _deliver(c, 'a', 'moon');
      final d = _quest(c, 'd');
      expect(c.sideQuestDialogue(d), 'Default d');
      await _deliver(c, 'd', 'moon');
      expect(c.sideQuestDialogue(d), 'My own delivered route.');
      await _deliver(c, 'b', 'moon');
      expect(c.sideQuestDialogue(_quest(c, 'a')), 'B is remembered.');
      expect(await c.flush(), isTrue);
      c.dispose();
    },
  );

  test(
    'transitive requirements reject incompatible branches but keep an OR intersection',
    () {
      final json = _definition(enriched: false).toJson();
      json['sideQuests'][1]['requires'] = [
        _require('a', ['sun']),
      ];
      json['sideQuests'][2]['requires'] = [
        _require('a', ['moon']),
      ];
      json['sideQuests'][3]['requires'] = [
        _require('b', ['sun', 'moon']),
        _require('c', ['sun', 'moon']),
      ];
      expect(
        () => VrlzExpeditionDefinition.fromJson(json),
        throwsFormatException,
      );
      json['sideQuests'][2]['requires'] = [
        _require('a', ['sun', 'moon']),
      ];
      expect(VrlzExpeditionDefinition.fromJson(json).sideQuests.length, 4);
    },
  );

  test(
    'dialogue variants reject direct and transitive contradictions with quest ancestors',
    () {
      final direct = _definition().toJson();
      direct['sideQuests'][3]['dialogueVariants'] = [
        {
          'requires': [
            _require('a', ['sun']),
          ],
          'dialogue': 'Contradicts d requiring a=moon.',
        },
      ];
      expect(
        () => VrlzExpeditionDefinition.fromJson(direct),
        throwsFormatException,
      );

      final transitive = _definition().toJson();
      transitive['sideQuests'][3]['dialogueVariants'] = [
        {
          'requires': [
            _require('c', ['sun', 'moon']),
          ],
          'dialogue': 'Contradicts d=moon through c requiring a=sun.',
        },
      ];
      expect(
        () => VrlzExpeditionDefinition.fromJson(transitive),
        throwsFormatException,
      );
    },
  );

  test(
    'legacy progress enriches dialogue without new state flags or writes',
    () async {
      final store = ExpeditionMemoryStore();
      final old = await _open(store: store, enriched: false);
      await _unlock(old);
      await _deliver(old, 'a', 'sun');
      final bytes = Uint8List.fromList(store.bytes!);
      old.dispose();
      final c = await _open(store: store);
      expect(c.isSideQuestUnlocked(_quest(c, 'b')), isTrue);
      expect(
        c.sideQuestDialogue(_quest(c, 'b')),
        'The sun route was delivered.',
      );
      expect(await c.flush(), isTrue);
      expect(store.bytes, bytes);
      final snapshot = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      expect(snapshot.keys.toSet(), {
        'schema',
        'id',
        'experienceId',
        'revision',
        'visitedWorlds',
        'completedMissions',
        'sideQuests',
      });
      c.dispose();
    },
  );

  test(
    'valid dependency history restores independently of map order',
    () async {
      final store = ExpeditionMemoryStore()..bytes = _bytes(_snapshot());
      final c = await _open(store: store);
      expect(c.focusedSideQuestId, 'c');
      expect(c.pendingSideQuestId, 'c');
      expect(c.isSideQuestUnlocked(_quest(c, 'c')), isTrue);
      expect(c.sideProgress['a']?.completedAt?.toIso8601String(), _t1);
      expect(await c.flush(), isTrue);
      expect(store.writes, 0);
      c.dispose();
    },
  );

  test(
    'failed prerequisite save retries atomically with its dependent choice',
    () async {
      final store = ExpeditionMemoryStore();
      final active = await _open(store: store);
      await _unlock(active);
      active.chooseSideQuest('a', 'sun', 'garden', _giver);
      active.visit('gallery');
      active.interactSideQuest('a', 'gallery', _object);
      expect(await active.flush(), isTrue);
      store.failWrites = 1;
      active.completeSideQuest('a', 'garden', _giver);
      expect(await active.flush(), isFalse);
      expect(active.chooseSideQuest('b', 'moon', 'garden', _giver), isTrue);
      expect(await active.flush(), isTrue);
      final restored = await _open(store: store);
      expect(restored.sideProgress['a']?.completedAt, isNotNull);
      expect(restored.focusedSideQuestId, 'b');
      expect(restored.isSideQuestUnlocked(_quest(restored, 'b')), isTrue);
      active.dispose();
      restored.dispose();
    },
  );

  final badDefinitions = <String, void Function(Map<String, dynamic>)>{
    'null requirements': (j) => j['sideQuests'][1]['requires'] = null,
    'too many requirements': (j) => j['sideQuests'][1]['requires'] = [
      for (var i = 0; i < 9; i++) _require('a', ['sun']),
    ],
    'duplicate prerequisite': (j) => j['sideQuests'][1]['requires'] = [
      _require('a', ['sun']),
      _require('a', ['moon']),
    ],
    'self unlock': (j) => j['sideQuests'][1]['requires'] = [
      _require('b', ['sun']),
    ],
    'unknown prerequisite': (j) => j['sideQuests'][1]['requires'] = [
      _require('unknown', ['sun']),
    ],
    'unknown prerequisite choice': (j) => j['sideQuests'][1]['requires'] = [
      _require('a', ['unknown']),
    ],
    'empty OR': (j) => j['sideQuests'][1]['requires'] = [_require('a', [])],
    'long OR': (j) => j['sideQuests'][1]['requires'] = [
      _require('a', ['sun', 'moon', 'other']),
    ],
    'duplicate OR': (j) => j['sideQuests'][1]['requires'] = [
      _require('a', ['sun', 'sun']),
    ],
    'nonstrings OR': (j) => j['sideQuests'][1]['requires'] = [
      {
        'questId': 'a',
        'choiceIds': [1],
      },
    ],
    'unsafe prerequisite ID': (j) => j['sideQuests'][1]['requires'] = [
      _require('../a', ['sun']),
    ],
    'requirement extra key': (j) => j['sideQuests'][1]['requires'] = [
      _require('a', ['sun'])..['script'] = 'run',
    ],
    'missing choices': (j) => j['sideQuests'][1]['requires'] = [
      {'questId': 'a'},
    ],
    'two-node cycle': (j) => j['sideQuests'][0]['requires'] = [
      _require('b', ['sun']),
    ],
    'three-node cycle': (j) => j['sideQuests'][0]['requires'] = [
      _require('c', ['sun']),
    ],
    'null variants': (j) => j['sideQuests'][1]['dialogueVariants'] = null,
    'too many variants': (j) => j['sideQuests'][1]['dialogueVariants'] = [
      for (var i = 0; i < 17; i++)
        {
          'requires': [
            _require('a', ['sun']),
          ],
          'dialogue': 'D',
        },
    ],
    'variant without conditions': (j) =>
        j['sideQuests'][1]['dialogueVariants'] = [
          {'requires': [], 'dialogue': 'D'},
        ],
    'variant duplicate conditions': (j) =>
        j['sideQuests'][1]['dialogueVariants'] = [
          {
            'requires': [
              _require('a', ['sun']),
              _require('a', ['moon']),
            ],
            'dialogue': 'D',
          },
        ],
    'variant unknown reference': (j) =>
        j['sideQuests'][1]['dialogueVariants'] = [
          {
            'requires': [
              _require('unknown', ['sun']),
            ],
            'dialogue': 'D',
          },
        ],
    'variant unknown choice': (j) => j['sideQuests'][1]['dialogueVariants'] = [
      {
        'requires': [
          _require('a', ['unknown']),
        ],
        'dialogue': 'D',
      },
    ],
    'variant missing dialogue': (j) =>
        j['sideQuests'][1]['dialogueVariants'] = [
          {
            'requires': [
              _require('a', ['sun']),
            ],
          },
        ],
    'variant empty dialogue': (j) => j['sideQuests'][1]['dialogueVariants'] = [
      {
        'requires': [
          _require('a', ['sun']),
        ],
        'dialogue': '',
      },
    ],
    'variant long dialogue': (j) => j['sideQuests'][1]['dialogueVariants'] = [
      {
        'requires': [
          _require('a', ['sun']),
        ],
        'dialogue': 'x' * 1025,
      },
    ],
    'variant extra field': (j) => j['sideQuests'][1]['dialogueVariants'] = [
      {
        'requires': [
          _require('a', ['sun']),
        ],
        'dialogue': 'D',
        'url': 'https://invalid.test',
      },
    ],
  };
  for (final entry in badDefinitions.entries) {
    test('story definition rejects ${entry.key}', () {
      final json = _definition().toJson();
      entry.value(json);
      expect(
        () => VrlzExpeditionDefinition.fromJson(json),
        throwsFormatException,
      );
    });
  }

  final corrupt = <String, void Function(Map<String, dynamic>)>{
    'missing prerequisite': (j) => j['sideQuests'].remove('a'),
    'prerequisite pending': (j) {
      j['sideQuests'].remove('c');
      j['sideQuests']['a'].remove('completedAt');
      j['focusedSideQuestId'] = 'a';
    },
    'wrong OR branch': (j) => j['sideQuests']['a']['choiceId'] = 'moon',
    'wrong AND branch': (j) => j['sideQuests']['b']['choiceId'] = 'sun',
    'dependent before prerequisite': (j) =>
        j['sideQuests']['a']['completedAt'] = _t3,
    'completion before second prerequisite': (j) {
      j['sideQuests']['c'] = _progress('sun', _t1);
      j.remove('focusedSideQuestId');
    },
    'focused locked continuation': (j) {
      j.remove('sideQuests');
      j['focusedSideQuestId'] = 'b';
    },
    'focused wrong branch': (j) {
      j['sideQuests'].remove('c');
      j['focusedSideQuestId'] = 'd';
    },
  };
  for (final entry in corrupt.entries) {
    test(
      'story restore rejects ${entry.key} atomically without overwriting',
      () async {
        final json = _snapshot();
        entry.value(json);
        final bytes = _bytes(json), store = ExpeditionMemoryStore();
        store.bytes = bytes;
        final c = VrlzExpeditionController(
          definition: _definition(),
          store: store,
        );
        await expectLater(c.restore(), throwsFormatException);
        expect(c.ready, isFalse);
        expect(c.sideProgress, isEmpty);
        expect(c.completedMissions, isEmpty);
        expect(await c.flush(), isFalse);
        expect(store.writes, 0);
        expect(store.bytes, bytes);
        c.dispose();
      },
    );
  }
}

VrlzExpeditionSideQuest _quest(VrlzExpeditionController c, String id) =>
    c.definition.sideQuests.firstWhere((q) => q.id == id);
Future<VrlzExpeditionController> _open({
  ExpeditionMemoryStore? store,
  bool enriched = true,
}) async {
  final c = VrlzExpeditionController(
    definition: _definition(enriched: enriched),
    store: store ?? ExpeditionMemoryStore(),
  );
  await c.restore();
  return c;
}

Future<void> _unlock(VrlzExpeditionController c) async {
  c.visit('garden');
  expect(c.complete('first', 'garden', [1, 1.6, 2]), isTrue);
  expect(await c.flush(), isTrue);
}

Future<void> _deliver(
  VrlzExpeditionController c,
  String id,
  String choice,
) async {
  expect(c.chooseSideQuest(id, choice, 'garden', _giver), isTrue);
  expect(c.visit('gallery'), isTrue);
  expect(c.interactSideQuest(id, 'gallery', _object), isTrue);
  expect(c.completeSideQuest(id, 'garden', _giver), isTrue);
  expect(await c.flush(), isTrue);
}

Map<String, dynamic> _require(String quest, List<String> choices) => {
  'questId': quest,
  'choiceIds': choices,
};
VrlzExpeditionDefinition _definition({bool enriched = true}) {
  final json = expeditionFixture().toJson();
  Map<String, dynamic> side(String id) => {
    'id': id,
    'title': 'Story $id',
    'afterMissionId': 'first',
    'world': 'garden',
    'giver': {
      'id': 'guide_$id',
      'name': 'Guide',
      'dialogue': 'Default $id',
      'species': 'orb',
      'position': _giver.toList(),
      'radius': 2.5,
    },
    'choices': [
      for (final choice in ['sun', 'moon'])
        {
          'id': choice,
          'label': choice,
          'dialogue': 'Choice $choice',
          'discovery': 'Remembered $choice',
          'route': ['gallery'],
          'object': {
            'id': 'object_$id',
            'label': 'Record',
            'kind': 'examine',
            'position': _object.toList(),
            'radius': 2.5,
          },
        },
    ],
  };
  final stories = [
    for (final id in ['a', 'b', 'c', 'd']) side(id),
  ];
  if (enriched) {
    stories[1]['requires'] = [
      _require('a', ['sun', 'moon']),
    ];
    stories[1]['dialogueVariants'] = [
      {
        'requires': [
          _require('a', ['sun']),
        ],
        'dialogue': 'The sun route was delivered.',
      },
      {
        'requires': [
          _require('a', ['sun', 'moon']),
        ],
        'dialogue': 'A route was delivered.',
      },
    ];
    stories[2]['requires'] = [
      _require('a', ['sun']),
      _require('b', ['moon']),
    ];
    stories[3]['requires'] = [
      _require('a', ['moon']),
    ];
    stories[3]['dialogueVariants'] = [
      {
        'requires': [
          _require('d', ['moon']),
        ],
        'dialogue': 'My own delivered route.',
      },
    ];
  }
  json['sideQuests'] = stories;
  return VrlzExpeditionDefinition.fromJson(json);
}

Map<String, dynamic> _progress(String choice, String? completed) => {
  'choiceId': choice,
  'visitedStops': completed == null ? 0 : 1,
  'collected': completed != null,
  if (completed != null) 'completedAt': completed,
};
Map<String, dynamic> _snapshot() => {
  'schema': 1,
  'id': 'openneom.expedition',
  'experienceId': 'openneom.worlds',
  'revision': 1,
  'visitedWorlds': {'garden': _t0, 'gallery': _t0},
  'completedMissions': {'first': _t0},
  'sideQuests': {
    'c': _progress('sun', null),
    'b': _progress('moon', _t2),
    'a': _progress('sun', _t1),
  },
  'focusedSideQuestId': 'c',
};
Uint8List _bytes(Object json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));
