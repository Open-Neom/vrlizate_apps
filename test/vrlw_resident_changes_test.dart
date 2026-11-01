import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_apps/src/viewer/vrlw_resident_changes.dart';
import 'package:vrlizate_world/vrlizate_world.dart';

void main() {
  final grid = VrRegionGrid(
    world: VrWorldAddress(worldId: 'test', instanceId: 'local'),
    gridId: 'v1',
    cellSizeMeters: 10,
  );
  VrRegionSnapshot<String> snapshot(
    Map<VrRegionKey, VrRegionData<String>> resident, {
    int pending = 0,
    VrRegionKey? current,
    Map<VrRegionKey, Object> errors = const {},
  }) => VrRegionSnapshot(
    current: current,
    resident: resident,
    demanded: {if (current != null) current},
    residentBytes: resident.length,
    inFlightLoads: pending,
    errors: errors,
  );

  test(
    'cache maintenance and load status do not rebuild resident instances',
    () {
      final changes = VrlwResidentChanges<String>();
      final key = grid.key(0, 0), other = grid.key(1, 0);
      final region = VrRegionData(value: 'mesh', sizeBytes: 1);
      expect(changes.update(snapshot({key: region})), isTrue);
      // prune() creates a fresh snapshot but keeps the same region data.
      expect(changes.update(snapshot({key: region})), isFalse);
      expect(changes.update(snapshot({key: region}, pending: 2)), isFalse);
      expect(changes.update(snapshot({key: region}, current: other)), isFalse);
    },
  );

  test(
    'addition, eviction and same-coordinate replacement rebuild geometry',
    () {
      final changes = VrlwResidentChanges<String>();
      final a = grid.key(0, 0), b = grid.key(1, 0);
      final first = VrRegionData(value: 'first', sizeBytes: 1);
      final second = VrRegionData(value: 'second', sizeBytes: 1);
      expect(changes.update(snapshot({a: first})), isTrue);
      expect(changes.update(snapshot({a: first, b: second})), isTrue);
      expect(changes.update(snapshot({a: first})), isTrue);
      expect(changes.update(snapshot({a: second})), isTrue);
      expect(changes.update(snapshot({})), isTrue);
      expect(changes.update(snapshot({})), isFalse);
    },
  );

  test('load failure reaches the host without requiring geometry changes', () {
    final changes = VrlwResidentChanges<String>();
    final key = grid.key(0, 0);
    expect(changes.update(snapshot({})), isFalse);
    expect(
      changes.update(snapshot({}, errors: {key: StateError('decode failed')})),
      isTrue,
    );
  });

  test(
    'real cache prune notifications preserve the uploaded resident set',
    () async {
      final changes = VrlwResidentChanges<String>();
      final cache = VrRegionCache<String>(
        grid: grid,
        provider: (key, _) async =>
            VrRegionData(value: key.cacheKey, sizeBytes: 1),
        prefetchRadiusCells: 0,
        retentionRadiusCells: 0,
      );
      var rebuilds = 0;
      final subscription = cache.changes.listen((snapshot) {
        if (changes.update(snapshot)) rebuilds++;
      });
      addTearDown(() async {
        await subscription.cancel();
        cache.dispose();
      });
      cache.updatePosition(VrWorldPosition(0, 0, 0));
      await cache.waitForIdle();
      await Future<void>.delayed(Duration.zero);
      expect(rebuilds, 1);
      for (var i = 0; i < 5; i++) {
        cache.prune();
      }
      await Future<void>.delayed(Duration.zero);
      expect(rebuilds, 1);
      cache.updatePosition(VrWorldPosition(11, 0, 0));
      await cache.waitForIdle();
      await Future<void>.delayed(Duration.zero);
      expect(rebuilds, greaterThan(1));
    },
  );
}
