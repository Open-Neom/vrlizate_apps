import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;
import 'package:vrlizate_apps/src/viewer/vrlw_motion_runtime.dart';
import 'package:vrlizate_apps/src/viewer/vrlw_world_activity.dart';
import 'package:vrlizate_world/vrlizate_world.dart';

VrlwWorldActivity _activity() => VrlwWorldActivity(
  VrlwBundleIndex(
    header: VrlwBundleHeader(2, 0),
    id: 'motion-runtime',
    title: 'Motion runtime',
    revision: '1.0.0-beta.1',
    license: 'MIT',
    gridId: 'grid',
    cellSizeMeters: 32,
    prototypeIds: {'model'},
    origin: {'type': 'local'},
    indexSha256: '0' * 64,
    chunks: [],
    resources: [],
    prototypeBindings: [],
    motions: [
      VrlwMotionSpec(
        id: 'spin',
        prototypeId: 'model',
        node: 'rotor',
        kind: 'spin',
        axis: 'y',
        periodSeconds: 2,
        pivot: [1, 2, 3],
      ),
      VrlwMotionSpec(
        id: 'bob',
        prototypeId: 'model',
        node: 'lamp',
        kind: 'bob',
        axis: 'x',
        periodSeconds: 3,
        amplitude: .5,
      ),
      VrlwMotionSpec(
        id: 'path',
        prototypeId: 'model',
        node: 'person',
        kind: 'path',
        axis: 'y',
        periodSeconds: 4,
        waypoints: [
          [0, 0, 0],
          [5, 0, 0],
          [5, 0, 5],
          [0, 0, 5],
        ],
      ),
    ],
    interactions: [
      for (final id in ['spin', 'bob', 'path'])
        VrlwInteractionSpec(
          id: 'toggle-$id',
          label: id,
          position: [0, 0, 0],
          action: 'toggleMotion',
          target: id,
        ),
    ],
  ),
);

class _Batch {
  final transforms = <vm.Matrix4>[];
  int writes = 0;
  late final batch = VrlwMotionBatch((apply) {
    writes++;
    apply(transforms);
  });
}

class _Instance {
  _Instance(this.motionId, this.entity, this.local, this.center, this.range);
  final String motionId;
  final vm.Matrix4 entity, local;
  final vm.Vector3 center;
  final double range;
  late vm.Matrix4 actual;

  void add(VrlwMotionRuntime runtime, _Batch batch) {
    actual = entity
        .multiplied(runtime.activity.delta(motionId))
        .multiplied(local);
    final slot = batch.transforms.length;
    batch.transforms.add(actual.clone());
    runtime.add(
      batch: batch.batch,
      motionId: motionId,
      slot: slot,
      entityTransform: entity,
      localTransform: local,
      center: center,
      range: range,
    );
  }
}

void _matrixNear(vm.Matrix4 actual, vm.Matrix4 expected) {
  for (var i = 0; i < 16; i++) {
    expect(actual.storage[i], closeTo(expected.storage[i], 1e-9));
  }
}

_Instance _instance(String id, {double x = 0, double range = 20}) => _Instance(
  id,
  vm.Matrix4.translationValues(x, 0, 0),
  vm.Matrix4.identity(),
  vm.Vector3(x, 0, 0),
  range,
);

void main() {
  test('samples one shared track and invalidates each changed batch once', () {
    final runtime = VrlwMotionRuntime(_activity());
    final batches = List.generate(3, (_) => _Batch());
    for (final batch in batches) {
      for (var i = 0; i < 4; i++) {
        _instance('spin', x: i.toDouble()).add(runtime, batch);
      }
    }
    final eye = vm.Vector3.zero();
    for (var i = 0; i < 3; i++) {
      runtime.update(eye, 1 / 120);
    }
    expect(runtime.sampledDeltas, 0);
    expect(batches.map((b) => b.writes), [0, 0, 0]);
    runtime.update(eye, 1 / 120);
    expect(runtime.sampledDeltas, 1);
    expect(batches.map((b) => b.writes), [1, 1, 1]);
  });

  test('matches per-instance path over motion, pause, distance and resume', () {
    final activity = _activity(), reference = _activity();
    final runtime = VrlwMotionRuntime(activity);
    final batches = List.generate(4, (_) => _Batch());
    final instances = <_Instance>[];
    final initialWinding = <bool>[];
    for (var batchIndex = 0; batchIndex < batches.length; batchIndex++) {
      for (var i = 0; i < 4; i++) {
        final x = i * 11.0;
        final instance = _Instance(
          ['spin', 'spin', 'bob', 'path'][batchIndex],
          vm.Matrix4.translationValues(x, i * .2, -batchIndex * 2.0)
            ..rotateY(i * .13)
            ..scaleByDouble(i.isOdd ? -1 : 1, 1.2, 1.4, 1),
          vm.Matrix4.translationValues(1, 2, 3)
            ..rotateX(batchIndex * .2)
            ..scaleByDouble(1, batchIndex.isOdd ? -1 : 1, 1, 1),
          vm.Vector3(x, 0, -batchIndex * 2.0),
          18,
        );
        instance.add(runtime, batches[batchIndex]);
        instances.add(instance);
        initialWinding.add(instance.actual.determinant() < 0);
      }
    }
    var accumulator = 0.0;
    for (var frame = 0; frame < 360; frame++) {
      if (frame == 60 || frame == 160) {
        activity.activate('toggle-spin', vm.Vector3.zero());
        reference.activate('toggle-spin', vm.Vector3.zero());
      }
      final eye = vm.Vector3(frame < 180 ? frame / 8 : (360 - frame) / 8, 0, 0);
      final dt = frame == 200 ? 2.0 : 1 / 120;
      // Original per-instance algorithm is the numerical oracle. The clock
      // advances per viewer frame; matrix writes keep the same 30 Hz cadence.
      final nearby = <String>{};
      for (final instance in instances) {
        if (eye.distanceToSquared(instance.center) <=
            instance.range * instance.range) {
          nearby.add(instance.motionId);
        }
      }
      reference.advance(dt, nearby);
      accumulator += dt.clamp(0, .1);
      if (accumulator >= 1 / 30) {
        accumulator %= 1 / 30;
        for (final instance in instances) {
          if (!nearby.contains(instance.motionId) ||
              !reference.motionEnabled(instance.motionId) ||
              eye.distanceToSquared(instance.center) >
                  instance.range * instance.range) {
            continue;
          }
          instance.actual = instance.entity
              .multiplied(reference.delta(instance.motionId))
              .multiplied(instance.local);
        }
      }
      runtime.update(eye, dt);
      expect(activity.activeSeconds, reference.activeSeconds);
      for (var i = 0; i < instances.length; i++) {
        final actual = batches[i ~/ 4].transforms[i % 4];
        _matrixNear(actual, instances[i].actual);
        expect(actual.determinant() < 0, initialWinding[i]);
        // A mirrored parent has its own parity, independent of the retained
        // local instance winding consumed by flutter_scene.
        final parent = vm.Matrix4.diagonal3Values(-1, 1, 1);
        expect(parent.multiplied(actual).determinant() < 0, !initialWinding[i]);
      }
    }
  });

  test('far slots freeze even when their shared track advances nearby', () {
    final activity = _activity(), runtime = VrlwMotionRuntime(_activity());
    final batch = _Batch();
    _instance('spin', range: 1).add(runtime, batch);
    _instance('spin', x: 30, range: 1).add(runtime, batch);
    final farPose = batch.transforms[1].clone();
    runtime.update(vm.Vector3(1, 0, 0), .1); // Inclusive reach boundary.
    activity.advance(.1, {'spin'});
    _matrixNear(batch.transforms[0], activity.delta('spin'));
    _matrixNear(batch.transforms[1], farPose);
    expect(batch.writes, 1);
    runtime.update(vm.Vector3(60, 0, 0), .1);
    expect(batch.writes, 1);
    expect(runtime.sampledDeltas, 1);
    runtime.update(vm.Vector3(30, 0, 0), .1);
    activity.advance(.1, {'spin'});
    _matrixNear(
      batch.transforms[1],
      vm.Matrix4.translationValues(30, 0, 0).multiplied(activity.delta('spin')),
    );
    expect(runtime.sampledDeltas, 2);
  });

  test('paused tracks skip writes while world time still advances', () {
    final activity = _activity(), runtime = VrlwMotionRuntime(_activity());
    final batch = _Batch();
    _instance('bob').add(runtime, batch);
    runtime.activity.activate('toggle-bob', vm.Vector3.zero());
    for (var i = 0; i < 6; i++) {
      runtime.update(vm.Vector3.zero(), .1);
    }
    expect(batch.writes, 0);
    expect(runtime.sampledDeltas, 0);
    expect(runtime.activity.activeSeconds, closeTo(.6, 1e-9));
    runtime.activity.activate('toggle-bob', vm.Vector3.zero());
    runtime.update(vm.Vector3.zero(), .1);
    activity.advance(.1, {'bob'});
    _matrixNear(batch.transforms.single, activity.delta('bob'));
    expect(batch.writes, 1);
  });

  test(
    'region replacement releases slots without resetting clock or cadence',
    () {
      final runtime = VrlwMotionRuntime(_activity());
      final oldBatch = _Batch(), nextBatch = _Batch();
      _instance('path').add(runtime, oldBatch);
      runtime.update(vm.Vector3.zero(), 1 / 60);
      runtime.clear();
      _instance('path', x: 1).add(runtime, nextBatch);
      runtime.update(vm.Vector3.zero(), 1 / 60);
      expect(oldBatch.writes, 0);
      expect(nextBatch.writes, 1);
      expect(runtime.sampledDeltas, 1);
      _matrixNear(
        nextBatch.transforms.single,
        vm.Matrix4.translationValues(
          1,
          0,
          0,
        ).multiplied(runtime.activity.delta('path')),
      );
      runtime.clear();
      runtime.update(vm.Vector3.zero(), .1);
      expect(nextBatch.writes, 1);
      expect(runtime.activity.activeSeconds, closeTo(1 / 30 + .1, 1e-9));
    },
  );

  test('invalid frame deltas neither write nor advance activity', () {
    final runtime = VrlwMotionRuntime(_activity());
    final batch = _Batch();
    _instance('spin').add(runtime, batch);
    for (final dt in [0.0, -1.0, double.nan, double.infinity]) {
      runtime.update(vm.Vector3.zero(), dt);
    }
    expect(runtime.activity.activeSeconds, 0);
    expect(runtime.sampledDeltas, 0);
    expect(batch.writes, 0);
  });
}
