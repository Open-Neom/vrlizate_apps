import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;
import 'package:vrlizate_apps/src/viewer/vrlw_world_activity.dart';
import 'package:vrlizate_world/vrlizate_world.dart';

VrlwWorldActivity _activity({
  String kind = 'spin',
  String axis = 'y',
  bool initiallyEnabled = true,
  List<double> pivot = const [1, 2, 3],
}) => VrlwWorldActivity(
  VrlwBundleIndex(
    header: VrlwBundleHeader(2, 0),
    id: 'activity-world',
    title: 'Activity world',
    revision: '1.0.0-beta.1',
    license: 'MIT',
    gridId: 'grid',
    cellSizeMeters: 32,
    prototypeIds: {'rotor-model'},
    origin: {'type': 'local'},
    indexSha256: '0' * 64,
    chunks: [],
    resources: [],
    prototypeBindings: [],
    motions: [
      VrlwMotionSpec(
        id: 'rotor',
        prototypeId: 'rotor-model',
        node: 'blade',
        kind: kind,
        axis: axis,
        periodSeconds: 2,
        pivot: pivot,
        amplitude: kind == 'bob' ? 0.5 : null,
        initiallyEnabled: initiallyEnabled,
      ),
    ],
    audioEmitters: const [
      VrlwAudioEmitter(id: 'wind', resource: 'ambience', x: 1, y: 2, z: 3),
    ],
    interactions: [
      VrlwInteractionSpec(
        id: 'motion-switch',
        label: 'Rotor',
        position: [1, 2, 3],
        action: 'toggleMotion',
        target: 'rotor',
      ),
      VrlwInteractionSpec(
        id: 'audio-switch',
        label: 'Sonido',
        position: [1, 2, 3],
        action: 'toggleAudio',
        target: 'wind',
      ),
    ],
  ),
);

void _ticks(
  VrlwWorldActivity activity,
  int count, {
  Set<String> nearby = const {'rotor'},
  bool active = true,
}) {
  for (var n = 0; n < count; n++) {
    activity.advance(.1, nearby, active: active);
  }
}

void _expectVector(vm.Vector3 actual, List<double> expected) {
  for (var i = 0; i < 3; i++) {
    expect(actual[i], closeTo(expected[i], 1e-9), reason: 'coordinate $i');
  }
}

void _expectMatrix(vm.Matrix4 actual, vm.Matrix4 expected) {
  for (var i = 0; i < 16; i++) {
    expect(
      actual.storage[i],
      closeTo(expected.storage[i], 1e-9),
      reason: 'matrix entry $i',
    );
  }
}

void main() {
  final axisExpectations = {
    'x': [1.0, 2.0, 4.0],
    'y': [1.0, 2.0, 2.0],
    'z': [0.0, 2.0, 3.0],
  };
  for (final entry in axisExpectations.entries) {
    test(
      'spin ${entry.key} preserves authored pivot and rotates quarter turn',
      () {
        final activity = _activity(axis: entry.key);
        _ticks(activity, 5);
        final delta = activity.delta('rotor');
        _expectVector(delta.transform3(vm.Vector3(1, 2, 3)), [1, 2, 3]);
        final point = entry.key == 'x'
            ? vm.Vector3(1, 3, 3)
            : entry.key == 'y'
            ? vm.Vector3(2, 2, 3)
            : vm.Vector3(1, 3, 3);
        _expectVector(delta.transform3(point), entry.value);
      },
    );
  }

  for (final axis in ['x', 'y', 'z']) {
    test(
      'bob $axis follows bounded sine without changing other coordinates',
      () {
        final activity = _activity(kind: 'bob', axis: axis);
        _ticks(activity, 5);
        final positive = [0.0, 0.0, 0.0];
        positive[['x', 'y', 'z'].indexOf(axis)] = .5;
        _expectVector(activity.delta('rotor').getTranslation(), positive);
        _ticks(activity, 10);
        _expectVector(
          activity.delta('rotor').getTranslation(),
          positive.map((v) => -v).toList(),
        );
        _ticks(activity, 5);
        _expectMatrix(activity.delta('rotor'), vm.Matrix4.identity());
      },
    );
  }

  test(
    'disabled initial motion stays at identity until explicitly activated',
    () {
      final activity = _activity(initiallyEnabled: false);
      _ticks(activity, 10);
      expect(activity.motionEnabled('rotor'), isFalse);
      _expectMatrix(activity.delta('rotor'), vm.Matrix4.identity());
      expect(
        activity.activate('motion-switch', vm.Vector3(1, 2, 3)),
        isNotNull,
      );
      _ticks(activity, 5);
      expect(
        activity.delta('rotor').storage[0],
        closeTo(math.cos(math.pi / 2), 1e-9),
      );
    },
  );

  test(
    'paused and distant tracks retain exact phase and resume incrementally',
    () {
      final activity = _activity();
      _ticks(activity, 3);
      final frozen = activity.delta('rotor');
      _ticks(activity, 50, active: false);
      _expectMatrix(activity.delta('rotor'), frozen);
      _ticks(activity, 50, nearby: {'unknown'});
      _expectMatrix(activity.delta('rotor'), frozen);
      _ticks(activity, 2);
      final reference = _activity();
      _ticks(reference, 5);
      _expectMatrix(activity.delta('rotor'), reference.delta('rotor'));
    },
  );

  test('invalid deltas do nothing and a resume gap advances at most 100ms', () {
    final activity = _activity();
    for (final dt in [
      0.0,
      -1.0,
      double.nan,
      double.infinity,
      double.negativeInfinity,
    ]) {
      activity.advance(dt, {'rotor'});
      _expectMatrix(activity.delta('rotor'), vm.Matrix4.identity());
    }
    activity.advance(120, {'rotor'});
    final reference = _activity();
    reference.advance(.1, {'rotor'});
    _expectMatrix(activity.delta('rotor'), reference.delta('rotor'));
  });

  test('proximity uses full 3D distance with an inclusive reach boundary', () {
    final activity = _activity();
    expect(activity.canActivate('motion-switch', vm.Vector3(4, 2, 3)), isTrue);
    expect(activity.canActivate('motion-switch', vm.Vector3(1, 5, 3)), isTrue);
    expect(
      activity.canActivate('motion-switch', vm.Vector3(4.001, 2, 3)),
      isFalse,
    );
    expect(activity.canActivate('motion-switch', vm.Vector3(3, 4, 5)), isFalse);
    expect(activity.canActivate('missing', vm.Vector3.zero()), isFalse);
    for (final value in [
      double.nan,
      double.infinity,
      double.negativeInfinity,
    ]) {
      expect(
        activity.canActivate('motion-switch', vm.Vector3(value, 2, 3)),
        isFalse,
      );
    }
    expect(activity.activate('motion-switch', vm.Vector3(20, 2, 3)), isNull);
    expect(activity.motionEnabled('rotor'), isTrue);
  });

  test(
    'toggle motion freezes its pose, debounce blocks duplicate input and resumes',
    () {
      final activity = _activity();
      final eye = vm.Vector3(1, 2, 3);
      _ticks(activity, 5);
      final pose = activity.delta('rotor');
      final item = activity.activate('motion-switch', eye)!;
      expect(activity.motionEnabled('rotor'), isFalse);
      expect(activity.indicatorEnabled(item), isFalse);
      _expectMatrix(activity.delta('rotor'), pose);
      expect(activity.activate('motion-switch', eye), isNull);
      _ticks(activity, 3);
      expect(activity.activate('motion-switch', eye), isNull);
      _expectMatrix(activity.delta('rotor'), pose);
      _ticks(activity, 2);
      expect(activity.activate('motion-switch', eye), same(item));
      expect(activity.indicatorEnabled(item), isTrue);
      _expectMatrix(activity.delta('rotor'), pose);
      _ticks(activity, 1);
      final reference = _activity();
      _ticks(reference, 6);
      _expectMatrix(activity.delta('rotor'), reference.delta('rotor'));
    },
  );

  test(
    'audio toggle is independent, uses same proximity/cooldown and local state',
    () {
      final activity = _activity();
      final eye = vm.Vector3(1, 2, 3);
      expect(activity.audioEnabled('wind'), isTrue);
      expect(activity.audioEnabled('unknown'), isFalse);
      final motion = activity.activate('motion-switch', eye)!;
      final audio = activity.activate('audio-switch', eye)!;
      expect(activity.indicatorEnabled(audio), isFalse);
      expect(activity.audioEnabled('wind'), isFalse);
      expect(activity.indicatorEnabled(motion), isFalse);
      expect(activity.activate('audio-switch', eye), isNull);
      _ticks(activity, 5, nearby: {});
      expect(activity.activate('audio-switch', eye), same(audio));
      expect(activity.indicatorEnabled(audio), isTrue);
      expect(activity.motionEnabled('rotor'), isFalse);
      expect(_activity().audioEnabled('wind'), isTrue);
    },
  );
}
