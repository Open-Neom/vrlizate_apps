import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_apps/src/viewer/vrlz_world_change_policy.dart';
import 'package:vrlizate_apps/vrlizate_apps_expedition.dart';

import 'support/vrlz_expedition_fixture.dart';

const _giver = <double>[0, 1.6, 0], _object = <double>[12, 1.6, 0];
const _prop = <double>[3, .8, 5], _access = <double>[8, 1.3, 9];

void main() {
  test(
    'selection is fresh, near and read-only rather than a retained node entitlement',
    () async {
      final store = ExpeditionMemoryStore();
      final c = VrlzExpeditionController(
        definition: _definition(),
        store: store,
      );
      final oldName = VrlzWorldChangePolicy.propName('impact_sun');
      expect(
        VrlzWorldChangePolicy.canInspect(c, 'garden', _prop, oldName),
        isFalse,
      );
      await c.restore();
      await _unlock(c);
      await _deliver(c, 'a');
      expect(
        VrlzWorldChangePolicy.canInspect(c, 'garden', _prop, oldName),
        isTrue,
      );
      expect(
        VrlzWorldChangePolicy.canInspect(c, 'gallery', _prop, oldName),
        isFalse,
      );
      expect(
        VrlzWorldChangePolicy.canInspect(c, 'garden', [100, 1.6, 0], oldName),
        isFalse,
      );
      expect(
        VrlzWorldChangePolicy.canInspect(c, 'garden', [
          double.nan,
          0,
          0,
        ], oldName),
        isFalse,
      );
      expect(
        VrlzWorldChangePolicy.canInspect(c, 'garden', _prop, 'stale'),
        isFalse,
      );
      final saved = Uint8List.fromList(store.bytes!), writes = store.writes;
      var notifications = 0;
      c.addListener(() => notifications++);
      for (var n = 0; n < 1000; n++) {
        VrlzWorldChangePolicy.canInspect(c, 'garden', _prop, oldName);
      }
      expect(await c.flush(), isTrue);
      expect(store.writes, writes);
      expect(store.bytes, saved);
      expect(notifications, 0);
      await _deliver(c, 'b');
      expect(
        VrlzWorldChangePolicy.canInspect(c, 'garden', _prop, oldName),
        isFalse,
      );
      expect(
        VrlzWorldChangePolicy.canInspect(
          c,
          'garden',
          _prop,
          VrlzWorldChangePolicy.propName('impact_advanced'),
        ),
        isTrue,
      );
      c.dispose();
      expect(
        VrlzWorldChangePolicy.canInspect(c, 'garden', _prop, oldName),
        isFalse,
      );
    },
  );

  test(
    'travel ticket rejects obsolete replacement, world, node and proximity',
    () async {
      final c = await _ready();
      final name = VrlzWorldChangePolicy.accessName('impact_sun');
      expect(
        VrlzWorldChangeTravelTicket.capture(c, 'garden', _access, 'old_node'),
        isNull,
      );
      expect(
        VrlzWorldChangeTravelTicket.capture(c, 'garden', [100, 1, 0], name),
        isNull,
      );
      expect(
        VrlzWorldChangeTravelTicket.capture(c, 'garden', [], name),
        isNull,
      );
      final ticket = VrlzWorldChangeTravelTicket.capture(
        c,
        'garden',
        _access,
        name,
      )!;
      expect(ticket.permits(c, 'garden', _access), isTrue);
      expect(ticket.permits(c, 'gallery', _access), isFalse);
      expect(ticket.permits(c, 'garden', [double.infinity, 0, 0]), isFalse);
      expect(ticket.permits(c, 'garden', [100, 0, 0]), isFalse);
      expect(() => ticket.position.clear(), throwsUnsupportedError);
      await _deliver(c, 'b');
      expect(ticket.permits(c, 'garden', _access), isFalse);
      c.dispose();
      expect(ticket.permits(c, 'garden', _access), isFalse);
    },
  );

  test(
    'same ID cannot reuse a ticket with another centre or destination',
    () async {
      final first = await _ready();
      final ticket = VrlzWorldChangeTravelTicket.capture(
        first,
        'garden',
        _access,
        VrlzWorldChangePolicy.accessName('impact_sun'),
      )!;
      final shifted = await _ready(access: <double>[8.1, 1.3, 9]);
      final redirected = await _ready(destination: 'coast');
      expect(ticket.permits(shifted, 'garden', _access), isFalse);
      expect(ticket.permits(redirected, 'garden', _access), isFalse);
      first.dispose();
      shifted.dispose();
      redirected.dispose();
    },
  );

  test(
    'task with same giver integrates reaction without a second talk target',
    () async {
      final c = await _ready(taskGiver: 'npc_a', taskWorld: 'garden');
      expect(VrlzWorldChangePolicy.canTalk(c, 'garden', _giver), isFalse);
      expect(VrlzWorldChangePolicy.taskReaction(c, 'garden')?.id, 'npc_a');
      expect(VrlzWorldChangePolicy.taskReaction(c, 'gallery'), isNull);
      c.dispose();
    },
  );

  test(
    'a different task NPC has visual priority and cannot impersonate reaction',
    () async {
      final c = await _ready(taskGiver: 'different_npc', taskWorld: 'garden');
      expect(VrlzWorldChangePolicy.canTalk(c, 'garden', _giver), isFalse);
      expect(VrlzWorldChangePolicy.taskReaction(c, 'garden'), isNull);
      expect(
        c.worldChange('garden')?.reaction?.dialogue,
        'A remembered decision.',
      );
      c.dispose();
    },
  );

  test(
    'reaction is available alone only near its current original position',
    () async {
      final c = await _ready(taskWorld: 'gallery');
      expect(VrlzWorldChangePolicy.canTalk(c, 'garden', _giver), isTrue);
      expect(VrlzWorldChangePolicy.canTalk(c, 'garden', [20, 1.6, 0]), isFalse);
      expect(
        VrlzWorldChangePolicy.canTalk(c, 'garden', [double.nan, 0, 0]),
        isFalse,
      );
      expect(VrlzWorldChangePolicy.taskReaction(c, 'garden'), isNull);
      c.dispose();
    },
  );

  test('loading-discarded build can retry the same intervention', () {
    final state = VrlzWorldChangeBuildState();
    final pending = state.begin('impact_sun');
    expect(state.matches(pending, 'impact_sun'), isTrue);
    // Creation was rejected while the save temporarily hid the world.
    expect(state.discard(pending), isTrue);
    expect(state.id, isNull);
    final retry = state.begin('impact_sun');
    expect(retry, isNot(pending));
    expect(state.matches(retry, 'impact_sun'), isTrue);
    expect(state.matches(pending, 'impact_sun'), isFalse);
  });

  test('late discard cannot erase a newer world or lifecycle build', () {
    final state = VrlzWorldChangeBuildState();
    final old = state.begin('impact_sun');
    state.invalidate();
    final newer = state.begin('impact_advanced');
    expect(state.discard(old), isFalse);
    expect(state.id, 'impact_advanced');
    expect(state.matches(newer, 'impact_advanced'), isTrue);
    expect(state.discard(newer), isTrue);
    expect(state.discard(newer), isFalse);
    expect(state.id, isNull);
  });

  for (final kind in ['planter', 'archive', 'beacon', 'shelter']) {
    test(
      '$kind geometry has bounded complexity and fits its reserved volume',
      () {
        final pieces = VrlzWorldPropPlan.pieces(kind);
        // Final shared volume includes the full-height shelter and archive
        // reading surface; authoring QA tests these against the real worlds.
        expect(pieces.length, lessThanOrEqualTo(12));
        expect(
          pieces.fold<int>(0, (total, piece) => total + piece.triangles),
          lessThanOrEqualTo(296),
        );
        expect(
          pieces.map((p) => p.surface).toSet().length,
          lessThanOrEqualTo(4),
        );
        for (final piece in pieces) {
          expect(piece.center.length, 3);
          expect(piece.size.length, 3);
          expect(piece.center.every((n) => n.isFinite), isTrue);
          expect(piece.size.every((n) => n.isFinite && n > 0), isTrue);
          final minimum = [
            for (var axis = 0; axis < 3; axis++)
              piece.center[axis] - piece.size[axis] / 2,
          ];
          final maximum = [
            for (var axis = 0; axis < 3; axis++)
              piece.center[axis] + piece.size[axis] / 2,
          ];
          expect(minimum[0], greaterThanOrEqualTo(-.8 - 1e-9));
          expect(maximum[0], lessThanOrEqualTo(.8 + 1e-9));
          expect(minimum[1], greaterThanOrEqualTo(-1e-9));
          expect(maximum[1], lessThanOrEqualTo(2.4 + 1e-9));
          expect(minimum[2], greaterThanOrEqualTo(-.6 - 1e-9));
          expect(maximum[2], lessThanOrEqualTo(.6 + 1e-9));
        }
      },
    );
  }
}

Future<VrlzExpeditionController> _ready({
  String taskGiver = 'npc_a',
  String taskWorld = 'gallery',
  List<double> access = _access,
  String destination = 'gallery',
}) async {
  final c = VrlzExpeditionController(
    definition: _definition(
      taskGiver: taskGiver,
      taskWorld: taskWorld,
      access: access,
      destination: destination,
    ),
    store: ExpeditionMemoryStore(),
  );
  await c.restore();
  await _unlock(c);
  await _deliver(c, 'a');
  return c;
}

Future<void> _unlock(VrlzExpeditionController c) async {
  c.visit('garden');
  expect(c.complete('first', 'garden', [1, 1.6, 2]), isTrue);
  expect(await c.flush(), isTrue);
}

Future<void> _deliver(VrlzExpeditionController c, String id) async {
  expect(c.chooseSideQuest(id, 'sun', 'garden', _giver), isTrue);
  c.visit('gallery');
  expect(c.interactSideQuest(id, 'gallery', _object), isTrue);
  expect(c.completeSideQuest(id, 'garden', _giver), isTrue);
  expect(await c.flush(), isTrue);
}

VrlzExpeditionDefinition _definition({
  String taskGiver = 'npc_a',
  String taskWorld = 'gallery',
  List<double> access = _access,
  String destination = 'gallery',
}) {
  final json = expeditionFixture().toJson();
  json['worlds']['coast'] = 'Coast';
  Map<String, dynamic> giver(String id) => {
    'id': id,
    'name': 'Guide',
    'dialogue': 'A remembered decision.',
    'species': 'robot',
    'position': _giver.toList(),
    'radius': 2.5,
  };
  Map<String, dynamic> object() => {
    'id': 'record',
    'label': 'Record',
    'kind': 'collect',
    'position': _object.toList(),
    'radius': 2.5,
  };
  json['missions'][1]['world'] = taskWorld;
  json['missions'][1]['giver'] = giver(taskGiver);
  json['missions'][1]['object'] = object();
  Map<String, dynamic> side(String id) => {
    'id': id,
    'title': 'Story $id',
    'afterMissionId': 'first',
    'world': 'garden',
    'giver': giver('npc_a'),
    'choices': [
      for (final choice in ['sun', 'moon'])
        {
          'id': choice,
          'label': choice,
          'dialogue': 'Choose',
          'discovery': 'A discovery',
          'route': ['gallery'],
          'object': object(),
        },
    ],
  };
  Map<String, dynamic> condition(String id) => {
    'questId': id,
    'choiceIds': ['sun'],
  };
  json['sideQuests'] = [
    side('a'),
    side('b')..['requires'] = [condition('a')],
  ];
  Map<String, dynamic> change(String id, List<Map<String, dynamic>> requires) =>
      {
        'id': id,
        'world': 'garden',
        'requires': requires,
        'prop': {
          'kind': 'archive',
          'label': 'Archive',
          'description': 'Remembered',
          'position': <double>[3, 0, 5],
          'radius': 2.5,
        },
        'access': {
          'label': 'Access',
          'destination': destination,
          'position': access.toList(),
          'radius': 3.5,
        },
        'reaction': giver('npc_a'),
      };
  json['worldChanges'] = [
    change('impact_advanced', [condition('a'), condition('b')]),
    change('impact_sun', [condition('a')]),
  ];
  // Decode once to exercise the same nested JSON map types as authored content.
  return VrlzExpeditionDefinition.fromBytes(
    Uint8List.fromList(utf8.encode(jsonEncode(json))),
  );
}
