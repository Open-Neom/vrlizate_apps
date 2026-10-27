import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_apps/vrlizate_apps_expedition.dart';

import 'support/vrlz_expedition_fixture.dart';

void main() {
  test(
    'restore gates transitions and empty state never writes a fabricated save',
    () async {
      final store = ExpeditionMemoryStore();
      final c = VrlzExpeditionController(
        definition: expeditionFixture(),
        store: store,
      );
      expect(c.ready, isFalse);
      expect(c.nextMission, isNull);
      expect(c.visit('garden'), isFalse);
      expect(c.complete('first', 'garden', [1, 1.6, 2]), isFalse);
      expect(await c.flush(), isFalse);
      await c.restore();
      expect(c.ready, isTrue);
      expect(c.nextMission?.id, 'first');
      expect(await c.flush(), isTrue);
      expect(store.writes, 0);
      c.dispose();
    },
  );

  test(
    'only visited, next, same-world and nearby finite positions complete',
    () async {
      final store = ExpeditionMemoryStore();
      final c = VrlzExpeditionController(
        definition: expeditionFixture(),
        store: store,
      );
      await c.restore();
      expect(c.complete('first', 'garden', [1, 1.6, 2]), isFalse);
      expect(c.visit('invented'), isFalse);
      expect(c.visit('garden'), isTrue);
      expect(c.complete('second', 'gallery', [4, 1.6, 4]), isFalse);
      expect(c.canComplete('first', 'gallery', [1, 1.6, 2]), isFalse);
      for (final p in <List<double>>[
        [9, 1.6, 2],
        [1, 8, 2],
        [double.nan, 1, 2],
        [double.infinity, 1, 2],
        [1, 2],
        [1, 2, 3, 4],
      ]) {
        expect(c.complete('first', 'garden', p), isFalse, reason: '$p');
      }
      expect(c.canComplete('first', 'garden', [3.5, 1.6, 2]), isTrue);
      expect(c.complete('first', 'garden', [3.5, 1.6, 2]), isTrue);
      expect(c.nextMission?.id, 'second');
      expect(c.complete('first', 'garden', [1, 1.6, 2]), isFalse);
      expect(c.complete('second', 'gallery', [4, 1.6, 4]), isFalse);
      expect(c.visit('gallery'), isTrue);
      expect(c.complete('second', 'gallery', [4, 1.6, 4]), isTrue);
      expect(c.complete('third', 'gallery', [7, 1.6, 5]), isTrue);
      expect(c.nextMission, isNull);
      expect(await c.flush(), isTrue);
      expect(c.completedMissions.keys, ['first', 'second', 'third']);
      c.dispose();
    },
  );

  test(
    'progress reload keeps timestamps and survives content/title changes',
    () async {
      final store = ExpeditionMemoryStore();
      final c = VrlzExpeditionController(
        definition: expeditionFixture(),
        store: store,
      );
      await c.restore();
      c.visit('garden');
      c.complete('first', 'garden', [1, 1.6, 2]);
      expect(await c.flush(), isTrue);
      final dates = c.completedMissions, visits = c.visitedWorlds;
      c.dispose();
      final fresh = VrlzExpeditionController(
        definition: expeditionFixture(title: 'Nueva textura, mismo recorrido'),
        store: store,
      );
      await fresh.restore();
      expect(fresh.completedMissions, dates);
      expect(fresh.visitedWorlds, visits);
      expect(fresh.nextMission?.id, 'second');
      expect(store.writes, 1);
      expect(() => fresh.visitedWorlds.clear(), throwsUnsupportedError);
      expect(() => fresh.completedMissions.clear(), throwsUnsupportedError);
      fresh.dispose();
    },
  );

  test(
    'duplicate frames neither notify nor enqueue redundant writes',
    () async {
      final store = ExpeditionMemoryStore();
      final c = VrlzExpeditionController(
        definition: expeditionFixture(),
        store: store,
      );
      await c.restore();
      var notifications = 0;
      c.addListener(() => notifications++);
      c.visit('garden');
      c.complete('first', 'garden', [1, 1.6, 2]);
      for (var i = 0; i < 1000; i++) {
        expect(c.visit('garden'), isFalse);
        expect(c.complete('first', 'garden', [1, 1.6, 2]), isFalse);
      }
      expect(await c.flush(), isTrue);
      expect(store.writes, 1);
      expect(notifications, 2);
      c.dispose();
    },
  );

  test(
    'writes serialize and coalesce mutations accepted during an active save',
    () async {
      final store = ExpeditionMemoryStore();
      final c = VrlzExpeditionController(
        definition: expeditionFixture(),
        store: store,
      );
      await c.restore();
      final gate = Completer<void>();
      store.nextWriteGate = gate;
      c.visit('garden');
      final first = c.flush();
      c.complete('first', 'garden', [1, 1.6, 2]);
      c.visit('gallery');
      c.complete('second', 'gallery', [4, 1.6, 4]);
      final second = c.flush();
      expect(identical(first, second), isTrue);
      expect(store.writes, 1);
      gate.complete();
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(store.maxActiveWrites, 1);
      expect(store.writes, 2);
      final saved = jsonDecode(utf8.decode(store.bytes!)) as Map;
      expect((saved['completedMissions'] as Map).keys, ['first', 'second']);
      c.dispose();
    },
  );

  test(
    'failed write never confirms durability, retains dirty state and retries',
    () async {
      final store = ExpeditionMemoryStore()..failWrites = 1;
      final c = VrlzExpeditionController(
        definition: expeditionFixture(),
        store: store,
      );
      await c.restore();
      c.visit('garden');
      c.complete('first', 'garden', [1, 1.6, 2]);
      expect(await c.flush(), isFalse);
      expect(store.bytes, isNull);
      expect(store.writes, 1);
      expect(c.saveError, isNotNull);
      expect(c.saveError, isNot(contains('token')));
      expect(await c.flush(), isTrue);
      expect(store.writes, 2);
      expect(c.saveError, isNull);
      expect(
        jsonDecode(utf8.decode(store.bytes!))['completedMissions'],
        hasLength(1),
      );
      c.dispose();
    },
  );

  test(
    'dispose drains accepted updates without later notifications or new events',
    () async {
      final store = ExpeditionMemoryStore();
      final c = VrlzExpeditionController(
        definition: expeditionFixture(),
        store: store,
      );
      await c.restore();
      var notifications = 0;
      c.addListener(() => notifications++);
      final gate = Completer<void>();
      store.nextWriteGate = gate;
      c.visit('garden');
      final saved = c.flush();
      c.complete('first', 'garden', [1, 1.6, 2]);
      c.dispose();
      final before = notifications;
      expect(c.ready, isFalse);
      expect(c.visit('gallery'), isFalse);
      expect(c.complete('second', 'gallery', [4, 1.6, 4]), isFalse);
      gate.complete();
      expect(await saved, isTrue);
      expect(notifications, before);
      expect(
        jsonDecode(utf8.decode(store.bytes!))['completedMissions'],
        hasLength(1),
      );
      expect(await c.flush(), isTrue);
      expect(store.maxActiveWrites, 1);
    },
  );

  test(
    'concurrent restore reads once and disposal does not publish late state',
    () async {
      final store = ExpeditionMemoryStore()..readGate = Completer<void>();
      final c = VrlzExpeditionController(
        definition: expeditionFixture(),
        store: store,
      );
      final a = c.restore(), b = c.restore();
      expect(identical(a, b), isTrue);
      expect(store.reads, 1);
      final failure = expectLater(a, throwsStateError);
      c.dispose();
      store.readGate!.complete();
      await failure;
      expect(c.ready, isFalse);
      expect(c.visitedWorlds, isEmpty);
      expect(store.writes, 0);
    },
  );

  test(
    'failed read retries explicitly without replacing progress with an empty file',
    () async {
      final store = ExpeditionMemoryStore()..failReads = 1;
      final c = VrlzExpeditionController(
        definition: expeditionFixture(),
        store: store,
      );
      await expectLater(c.restore(), throwsStateError);
      expect(c.ready, isFalse);
      expect(c.saveError, isNotNull);
      expect(await c.flush(), isFalse);
      expect(store.writes, 0);
      await c.restore();
      expect(c.ready, isTrue);
      expect(c.saveError, isNull);
      expect(store.reads, 2);
      c.dispose();
    },
  );

  test(
    'clock rollback keeps restored timestamps bounded and reloadable',
    () async {
      const latest = '9999-12-31T23:59:59.999999Z';
      final store = ExpeditionMemoryStore()
        ..bytes = _snapshot((x) {
          x['visitedWorlds'] = {'garden': latest};
          x['completedMissions'] = {};
        });
      final c = VrlzExpeditionController(
        definition: expeditionFixture(),
        store: store,
      );
      await c.restore();
      expect(c.complete('first', 'garden', [1, 1.6, 2]), isTrue);
      expect(c.completedMissions['first']?.toIso8601String(), latest);
      expect(await c.flush(), isTrue);
      final reloaded = VrlzExpeditionController(
        definition: expeditionFixture(),
        store: store,
      );
      await reloaded.restore();
      expect(reloaded.completedMissions, c.completedMissions);
      c.dispose();
      reloaded.dispose();
    },
  );

  final corrupt = <String, Uint8List Function()>{
    'empty': () => Uint8List(0),
    'oversized': () => Uint8List(32769),
    'bad utf8': () => Uint8List.fromList([255]),
    'invalid json': () => Uint8List.fromList(utf8.encode('{')),
    'array root': () => _bytes([]),
    'wrong schema': () => _snapshot((x) => x['schema'] = 2),
    'wrong identity': () => _snapshot((x) => x['id'] = 'other'),
    'wrong experience': () => _snapshot((x) => x['experienceId'] = 'other'),
    'wrong revision': () => _snapshot((x) => x['revision'] = 2),
    'unknown field': () => _snapshot((x) => x['reward'] = 99),
    'unknown visit': () =>
        _snapshot((x) => x['visitedWorlds'] = {'unknown': _date}),
    'out of order mission': () =>
        _snapshot((x) => x['completedMissions'] = {'second': _date}),
    'unvisited mission world': () => _snapshot((x) {
      x['visitedWorlds'] = {};
      x['completedMissions'] = {'first': _date};
    }),
    'completion before visit': () => _snapshot(
      (x) => x['completedMissions'] = {'first': '2025-01-01T00:00:00.000Z'},
    ),
    'unknown mission': () =>
        _snapshot((x) => x['completedMissions'] = {'unknown': _date}),
    'invalid timestamp': () => _snapshot(
      (x) => x['visitedWorlds'] = {'garden': '2026-99-99T00:00:00.000Z'},
    ),
    'noncanonical timestamp': () => _snapshot(
      (x) => x['visitedWorlds'] = {'garden': '2026-10-26T00:00:00+00:00'},
    ),
    'backwards sequence': () => _snapshot((x) {
      x['visitedWorlds'] = {'garden': _date, 'gallery': _date};
      x['completedMissions'] = {
        'first': '2026-10-27T00:00:00.000Z',
        'second': _date,
      };
    }),
  };
  for (final entry in corrupt.entries) {
    test(
      'restore rejects ${entry.key} without silently erasing original data',
      () async {
        final original = entry.value();
        final store = ExpeditionMemoryStore()..bytes = original;
        final c = VrlzExpeditionController(
          definition: expeditionFixture(),
          store: store,
        );
        await expectLater(c.restore(), throwsFormatException);
        expect(c.ready, isFalse);
        expect(c.visitedWorlds, isEmpty);
        expect(c.completedMissions, isEmpty);
        expect(await c.flush(), isFalse);
        expect(store.writes, 0);
        expect(store.bytes, original);
        c.dispose();
      },
    );
  }
}

const _date = '2026-10-26T00:00:00.000Z';
Uint8List _bytes(Object data) =>
    Uint8List.fromList(utf8.encode(jsonEncode(data)));
Uint8List _snapshot(void Function(Map<String, dynamic>) mutate) {
  final data = <String, dynamic>{
    'schema': 1,
    'id': 'openneom.expedition',
    'experienceId': 'openneom.worlds',
    'revision': 1,
    'visitedWorlds': {'garden': _date},
    'completedMissions': <String, String>{},
  };
  mutate(data);
  return _bytes(data);
}
