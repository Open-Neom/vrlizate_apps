import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_apps/src/viewer/vrlz_expedition_presenter.dart';
import 'package:vrlizate_apps/vrlizate_apps_expedition.dart';

import 'support/vrlz_expedition_fixture.dart';

const _giver = <double>[0, 1.6, 0], _object = <double>[12, 1.6, 0];

void main() {
  test(
    'interventions round trip immutable pure data with feet and portal centres',
    () {
      final definition = _definition(), json = _definition().toJson();
      expect(VrlzExpeditionDefinition.fromJson(json).toJson(), json);
      expect(() => definition.worldChanges.clear(), throwsUnsupportedError);
      final change = definition.worldChanges.first;
      expect(() => change.requires.clear(), throwsUnsupportedError);
      expect(() => change.prop!.position.clear(), throwsUnsupportedError);
      expect(() => change.access!.position.clear(), throwsUnsupportedError);
      json['worldChanges'][0]['prop']['position'][0] = 999.0;
      json['worldChanges'][0]['access']['position'][0] = 999.0;
      expect(change.prop!.position, [3, 0, 5]);
      expect(change.access!.position, [7, 1.3, 9]);
      expect(change.reaction!.id, 'guide_a');
      final position = <double>[1, 0, 2];
      final prop = VrlzExpeditionWorldProp(
        kind: 'planter',
        label: 'Planter',
        description: 'Original',
        position: position,
      );
      final access = VrlzExpeditionWorldAccess(
        label: 'Access',
        destination: 'gallery',
        position: position,
      );
      position.clear();
      expect(prop.position, [1, 0, 2]);
      expect(access.position, [1, 0, 2]);
      expect(prop.radius, 2.5);
      expect(access.radius, 3.5);
      for (final kind in ['planter', 'archive', 'beacon', 'shelter']) {
        expect(
          VrlzExpeditionWorldProp.fromJson({
            ...prop.toJson(),
            'kind': kind,
          }).kind,
          kind,
        );
      }
      for (final keep in ['prop', 'access', 'reaction']) {
        final one = change.toJson()
          ..removeWhere(
            (key, _) =>
                const {'prop', 'access', 'reaction'}.contains(key) &&
                key != keep,
          );
        expect(VrlzExpeditionWorldChange.fromJson(one).toJson(), one);
      }
    },
  );

  test('empty defaults keep old definitions and references unchanged', () {
    final old = expeditionFixture();
    expect(old.worldChanges, isEmpty);
    expect(old.toJson().containsKey('worldChanges'), isFalse);
    final json = _definition(changes: false).toJson();
    expect(json.containsKey('worldChanges'), isFalse);
    expect(VrlzExpeditionDefinition.fromJson(json).toJson(), json);
    final maximum = _definition().toJson();
    maximum['worldChanges'] = [
      for (var n = 0; n < 64; n++)
        <String, dynamic>{...maximum['worldChanges'][1], 'id': 'impact_$n'},
    ];
    expect(VrlzExpeditionDefinition.fromJson(maximum).worldChanges.length, 64);
  });

  test(
    'readiness, delivered choices and ordered priority determine the only active change',
    () async {
      final store = ExpeditionMemoryStore();
      final c = VrlzExpeditionController(
        definition: _definition(),
        store: store,
      );
      expect(c.worldChange('garden'), isNull);
      await c.restore();
      await _unlock(c);
      expect(c.worldChange('unknown'), isNull);
      expect(c.worldChange('garden'), isNull);
      c.chooseSideQuest('a', 'sun', 'garden', _giver);
      expect(c.worldChange('garden'), isNull);
      c.visit('gallery');
      c.interactSideQuest('a', 'gallery', _object);
      expect(c.worldChange('garden'), isNull);
      c.completeSideQuest('a', 'garden', _giver);
      expect(
        identical(c.worldChange('garden'), c.definition.worldChanges[1]),
        isTrue,
      );
      expect(c.worldChange('gallery')?.id, 'impact_remote');
      expect(await c.flush(), isTrue);
      var notices = 0;
      c.addListener(() => notices++);
      final writes = store.writes;
      for (var n = 0; n < 1000; n++) {
        expect(c.worldChange('garden')?.id, 'impact_sun');
      }
      expect(notices, 0);
      expect(store.writes, writes);
      await _deliver(c, 'b', 'sun');
      expect(
        identical(c.worldChange('garden'), c.definition.worldChanges.first),
        isTrue,
      );
      expect(c.worldChange('garden')?.id, 'impact_advanced');
      c.dispose();
      expect(c.worldChange('garden'), isNull);
    },
  );

  test(
    'another branch selects its own intervention and grants no alternate access',
    () async {
      final c = await _open();
      await _unlock(c);
      await _deliver(c, 'a', 'moon');
      expect(c.worldChange('garden')?.id, 'impact_moon');
      expect(c.worldChange('garden')?.access, isNull);
      expect(c.worldChange('garden')?.prop?.kind, 'shelter');
      expect(c.worldChange('gallery'), isNull);
      expect(c.worldChange('garden')?.reaction, isNull);
      c.dispose();
    },
  );

  test(
    'legacy delivered history activates canonical changes without any new stored flags',
    () async {
      final store = ExpeditionMemoryStore();
      final old = await _open(store: store, changes: false);
      await _unlock(old);
      await _deliver(old, 'a', 'sun');
      final bytes = Uint8List.fromList(store.bytes!);
      old.dispose();
      final current = await _open(store: store);
      expect(current.worldChange('garden')?.id, 'impact_sun');
      expect(await current.flush(), isTrue);
      expect(store.bytes, bytes);
      expect(
        (jsonDecode(utf8.decode(bytes)) as Map).containsKey('worldChanges'),
        isFalse,
      );
      expect(current.completedMissions.keys, ['first']);
      current.dispose();
    },
  );

  test(
    'failed writes do not publish an independent permanent world change',
    () async {
      final store = ExpeditionMemoryStore(), definition = _definition();
      final c = VrlzExpeditionController(definition: definition, store: store);
      await c.restore();
      await _unlock(c);
      c.chooseSideQuest('a', 'sun', 'garden', _giver);
      c.visit('gallery');
      c.interactSideQuest('a', 'gallery', _object);
      expect(await c.flush(), isTrue);
      store.failWrites = 1;
      c.completeSideQuest('a', 'garden', _giver);
      expect(await c.flush(), isFalse);
      expect(
        c.worldChange('garden')?.id,
        'impact_sun',
      ); // accepted in memory only.
      final durable = await _open(store: store);
      expect(durable.worldChange('garden'), isNull);
      expect(await c.flush(), isTrue);
      final recovered = await _open(store: store);
      expect(recovered.worldChange('garden')?.id, 'impact_sun');
      c.dispose();
      durable.dispose();
      recovered.dispose();
    },
  );

  test(
    'world conditions reject transitive contradictions and permit intersecting OR',
    () {
      final json = _definition().toJson();
      json['worldChanges'][0]['requires'] = [
        _require('a', ['moon']),
        _require('b', ['sun']),
      ];
      expect(
        () => VrlzExpeditionDefinition.fromJson(json),
        throwsFormatException,
      );
      json['worldChanges'][0]['requires'] = [
        _require('a', ['sun', 'moon']),
        _require('b', ['sun']),
      ];
      expect(VrlzExpeditionDefinition.fromJson(json).worldChanges.length, 4);
    },
  );

  test(
    'snapshot rejects injected world-change state instead of trusting independent flags',
    () async {
      final store = ExpeditionMemoryStore();
      final c = await _open(store: store);
      await _unlock(c);
      c.dispose();
      final json =
          jsonDecode(utf8.decode(store.bytes!)) as Map<String, dynamic>;
      json['worldChanges'] = ['impact_sun'];
      final original = Uint8List.fromList(utf8.encode(jsonEncode(json)));
      store.bytes = original;
      final restored = VrlzExpeditionController(
        definition: _definition(),
        store: store,
      );
      await expectLater(restored.restore(), throwsFormatException);
      expect(restored.worldChange('garden'), isNull);
      expect(await restored.flush(), isFalse);
      expect(store.bytes, original);
      restored.dispose();
    },
  );

  final invalid = <String, void Function(Map<String, dynamic>)>{
    'null collection': (j) => j['worldChanges'] = null,
    'nonlist collection': (j) => j['worldChanges'] = {},
    'too many changes': (j) => j['worldChanges'] = [
      for (var n = 0; n < 65; n++) {...j['worldChanges'][1], 'id': 'impact_$n'},
    ],
    'duplicate change ID': (j) =>
        j['worldChanges'][1]['id'] = 'impact_advanced',
    'main ID collision': (j) => j['worldChanges'][0]['id'] = 'first',
    'side ID collision': (j) => j['worldChanges'][0]['id'] = 'a',
    'unsafe change ID': (j) => j['worldChanges'][0]['id'] = '../impact',
    'unknown origin': (j) => j['worldChanges'][0]['world'] = 'unknown',
    'no intervention': (j) => j['worldChanges'][0].removeWhere(
      (key, _) => const {'prop', 'access', 'reaction'}.contains(key),
    ),
    'empty conditions': (j) => j['worldChanges'][0]['requires'] = [],
    'duplicate conditions': (j) => j['worldChanges'][0]['requires'] = [
      _require('a', ['sun']),
      _require('a', ['moon']),
    ],
    'too many conditions': (j) => j['worldChanges'][0]['requires'] = [
      for (var n = 0; n < 9; n++) _require('a', ['sun']),
    ],
    'unknown story': (j) => j['worldChanges'][0]['requires'] = [
      _require('unknown', ['sun']),
    ],
    'unknown decision': (j) => j['worldChanges'][0]['requires'] = [
      _require('a', ['unknown']),
    ],
    'null prop': (j) => j['worldChanges'][0]['prop'] = null,
    'unknown kind': (j) =>
        j['worldChanges'][0]['prop']['kind'] = 'custom_asset',
    'unsafe description': (j) =>
        j['worldChanges'][0]['prop']['description'] = '\u0001',
    'long description': (j) =>
        j['worldChanges'][0]['prop']['description'] = 'x' * 1025,
    'empty label': (j) => j['worldChanges'][0]['prop']['label'] = '',
    'prop ID forbidden': (j) => j['worldChanges'][0]['prop']['id'] = 'separate',
    'prop position': (j) =>
        j['worldChanges'][0]['prop']['position'] = [0, double.nan, 0],
    'prop bounds': (j) =>
        j['worldChanges'][0]['prop']['position'] = [1000001, 0, 0],
    'prop radius': (j) => j['worldChanges'][0]['prop']['radius'] = 11,
    'unknown destination': (j) =>
        j['worldChanges'][0]['access']['destination'] = 'unknown',
    'origin destination': (j) =>
        j['worldChanges'][0]['access']['destination'] = 'garden',
    'null access': (j) => j['worldChanges'][0]['access'] = null,
    'access ID forbidden': (j) =>
        j['worldChanges'][0]['access']['id'] = 'separate',
    'access coordinate shape': (j) =>
        j['worldChanges'][0]['access']['position'] = [0, 1],
    'access radius': (j) => j['worldChanges'][0]['access']['radius'] = 0,
    'null reaction': (j) => j['worldChanges'][0]['reaction'] = null,
    'reaction missing original ID': (j) =>
        j['worldChanges'][0]['reaction'].remove('id'),
    'reaction coordinate': (j) =>
        j['worldChanges'][0]['reaction']['position'] = [0, 0, double.infinity],
    'unknown top field': (j) =>
        j['worldChanges'][0]['url'] = 'https://invalid.test',
  };
  for (final entry in invalid.entries) {
    test('world intervention rejects ${entry.key}', () {
      final json = _definition().toJson();
      entry.value(json);
      expect(
        () => VrlzExpeditionDefinition.fromJson(json),
        throwsFormatException,
      );
    });
  }

  test(
    'passport summarizes active world consequences only after delivery and updates on override',
    () async {
      final store = ExpeditionMemoryStore();
      final c = await _open(store: store);
      await _unlock(c);
      expect(
        VrlzPassportPresentation(
          c,
        ).pages.where((p) => p.title == 'Consecuencias · Mundos'),
        isEmpty,
      );

      // Accepted and collected choices do not surface premature world changes.
      expect(c.chooseSideQuest('a', 'sun', 'garden', _giver), isTrue);
      expect(c.visit('gallery'), isTrue);
      expect(c.interactSideQuest('a', 'gallery', _object), isTrue);
      expect(
        VrlzPassportPresentation(
          c,
        ).pages.where((p) => p.title == 'Consecuencias · Mundos'),
        isEmpty,
      );

      // Delivery activates garden and gallery consequences in the passport.
      expect(c.completeSideQuest('a', 'garden', _giver), isTrue);
      var consequences = VrlzPassportPresentation(
        c,
      ).pages.where((p) => p.title == 'Consecuencias · Mundos').toList();
      expect(consequences, hasLength(1));
      expect(consequences.single.actions, isEmpty);
      expect(consequences.single.body, contains('Jardín: Changed place'));
      expect(consequences.single.body, contains('Galería: Changed place'));
      expect(consequences.single.body, isNot(contains('→ Galería')));

      // Delivering b upgrades garden to impact_advanced with shortcut to Galería.
      await _deliver(c, 'b', 'sun');
      consequences = VrlzPassportPresentation(
        c,
      ).pages.where((p) => p.title == 'Consecuencias · Mundos').toList();
      expect(
        consequences.single.body,
        contains('Jardín: Changed place → Galería'),
      );

      // Save failure still keeps Guardado pendiente as the final page.
      store.failWrites = 1;
      expect(c.complete('second', 'gallery', [4, 1.6, 4]), isTrue);
      expect(await c.flush(), isFalse);
      expect(
        VrlzPassportPresentation(c).pages.last.title,
        'Guardado pendiente',
      );
      c.dispose();
    },
  );
}

Future<VrlzExpeditionController> _open({
  ExpeditionMemoryStore? store,
  bool changes = true,
}) async {
  final c = VrlzExpeditionController(
    definition: _definition(changes: changes),
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

Map<String, dynamic> _require(String id, List<String> choices) => {
  'questId': id,
  'choiceIds': choices,
};
VrlzExpeditionDefinition _definition({bool changes = true}) {
  final json = expeditionFixture().toJson();
  Map<String, dynamic> giver() => {
    'id': 'guide_a',
    'name': 'Guide',
    'dialogue': 'The garden remembers.',
    'species': 'sprout',
    'position': _giver.toList(),
    'radius': 2.5,
  };
  Map<String, dynamic> side(String id) => {
    'id': id,
    'title': 'Story $id',
    'afterMissionId': 'first',
    'world': 'garden',
    'giver': giver(),
    'choices': [
      for (final choice in ['sun', 'moon'])
        {
          'id': choice,
          'label': choice,
          'dialogue': 'Choice $choice',
          'discovery': 'Remembered',
          'route': ['gallery'],
          'object': {
            'id': 'record_$id',
            'label': 'Record',
            'kind': 'collect',
            'position': _object.toList(),
            'radius': 2.5,
          },
        },
    ],
  };
  json['sideQuests'] = [
    side('a'),
    side('b')
      ..['requires'] = [
        _require('a', ['sun']),
      ],
  ];
  Map<String, dynamic> change(
    String id,
    String world,
    List<Map<String, dynamic>> requires,
    String kind,
  ) => {
    'id': id,
    'world': world,
    'requires': requires,
    'prop': {
      'kind': kind,
      'label': 'Changed place',
      'description': 'An original intervention',
      'position': <double>[3, 0, 5],
      'radius': 2.5,
    },
  };
  if (changes) {
    json['worldChanges'] = [
      change('impact_advanced', 'garden', [
          _require('a', ['sun']),
          _require('b', ['sun']),
        ], 'archive')
        ..['access'] = {
          'label': 'Archive route',
          'destination': 'gallery',
          'position': <double>[7, 1.3, 9],
          'radius': 3.5,
        }
        ..['reaction'] = giver(),
      change('impact_sun', 'garden', [
        _require('a', ['sun']),
      ], 'planter'),
      change('impact_moon', 'garden', [
        _require('a', ['moon']),
      ], 'shelter'),
      change('impact_remote', 'gallery', [
        _require('a', ['sun']),
      ], 'beacon'),
    ];
  }
  return VrlzExpeditionDefinition.fromJson(json);
}
