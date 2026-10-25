import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;
import 'package:vrlizate_apps/src/bundles/vrlw_audio_policy.dart';
import 'package:vrlizate_apps/src/viewer/vrlw_world_audio.dart';
import 'package:vrlizate_world/vrlizate_world.dart';

void main() {
  test('canonical WAV checks decoded duration and every header field', () {
    expect(VrlwAudioPolicy.validate(_wav()).sampleRate, 16000);
    expect(
      VrlwAudioPolicy.validate(_wav(seconds: 8)).duration,
      const Duration(seconds: 8),
    );
    expect(
      VrlwAudioPolicy.validate(_wav(rate: 22050, seconds: 5)).frameCount,
      110250,
    );
    for (final mutation in <void Function(ByteData)>[
      (d) => d.setUint32(4, 44, Endian.little),
      (d) => d.setUint32(16, 18, Endian.little),
      (d) => d.setUint16(20, 3, Endian.little),
      (d) => d.setUint16(22, 2, Endian.little),
      (d) => d.setUint32(24, 48000, Endian.little),
      (d) => d.setUint32(28, 1, Endian.little),
      (d) => d.setUint16(32, 4, Endian.little),
      (d) => d.setUint16(34, 8, Endian.little),
      (d) => d.setUint32(40, 13, Endian.little),
      (d) => d.setUint32(36, 0, Endian.little),
    ]) {
      final wav = _wav();
      mutation(ByteData.sublistView(wav));
      expect(() => VrlwAudioPolicy.validate(wav), throwsFormatException);
    }
    expect(
      () => VrlwAudioPolicy.validate(_wav(seconds: 9)),
      throwsFormatException,
    );
    expect(
      () => VrlwAudioPolicy.validate(_wav(rate: 22050, seconds: 8)),
      throwsFormatException,
    );
  });

  test(
    'starts inactive and plays only the two nearest voices at soft volume',
    () async {
      final output = _Output();
      final audio = _audio(
        output,
        emitters: [_e('far', 9), _e('a', -1), _e('b', 2)],
      );
      await audio.initialize();
      audio.update(listenerPosition: vm.Vector3.zero(), listenerYaw: 0);
      await _flush();
      expect(output.plays, isEmpty);
      audio.setActive(true);
      await _flush();
      expect(output.active.keys.toSet(), {'a', 'b'});
      expect(output.active.values.every((v) => v.$1 > 0 && v.$1 <= .2), isTrue);
      expect(output.active['a']!.$2, lessThan(0));
      expect(output.active['b']!.$2, greaterThan(0));
      await audio.dispose();
      expect(output.active, isEmpty);
    },
  );

  test('10Hz updates coalesce while native work is pending', () async {
    var time = Duration.zero;
    final output = _Output()..playGate = Completer<void>();
    final audio = _audio(output, now: () => time);
    await audio.initialize();
    audio.setActive(true);
    audio.update(listenerPosition: vm.Vector3(0, 0, 1), listenerYaw: 0);
    await _flush();
    for (var i = 1; i <= 60; i++) {
      time = Duration(milliseconds: i * 17);
      audio.update(listenerPosition: vm.Vector3(0, 0, 1), listenerYaw: i / 30);
    }
    output.playGate!.complete();
    await _flush();
    expect(output.plays.length, lessThanOrEqualTo(2));
    expect(output.updates, lessThanOrEqualTo(1));
    expect(output.active, hasLength(1));
    await audio.dispose();
  });

  test(
    'gradual sub-threshold changes accumulate against the applied value',
    () async {
      var time = Duration.zero;
      final output = _Output();
      final audio = _audio(output, now: () => time, masterGain: 1);
      await audio.initialize();
      audio.setActive(true);
      for (var i = 0; i <= 100; i++) {
        time = Duration(milliseconds: i * 100);
        audio.update(
          listenerPosition: vm.Vector3(3 + i * .01, 0, 0),
          listenerYaw: 0,
        );
        await _flush();
      }
      expect(output.updates, greaterThan(3));
      expect(output.active['main']!.$1, closeTo((1 - 4 / 30) / 4, .005));
      await audio.dispose();
    },
  );

  test(
    'emitter toggle global mute and pause stop without waiting for another tick',
    () async {
      final output = _Output();
      final audio = _audio(output, emitters: [_e('a', -1), _e('b', 2)]);
      await audio.initialize();
      audio.setActive(true);
      audio.update(listenerPosition: vm.Vector3.zero(), listenerYaw: 0);
      await _flush();
      audio.setEmitterEnabled('a', false);
      await _flush();
      expect(output.active.keys, ['b']);
      audio.setEnabled(false);
      expect(output.active, isEmpty);
      audio.setEnabled(true);
      await _flush();
      expect(output.active.keys, ['b']);
      audio.setActive(false);
      expect(output.active, isEmpty);
      await audio.dispose();
    },
  );

  test('a late play completion cannot resurrect a paused world', () async {
    final output = _Output()..playGate = Completer<void>();
    final audio = _audio(output);
    await audio.initialize();
    audio.setActive(true);
    audio.update(listenerPosition: vm.Vector3.zero(), listenerYaw: 0);
    await _flush();
    audio.setActive(false);
    output.playGate!.complete();
    await _flush();
    expect(output.active, isEmpty);
    expect(output.stops, contains('main'));
    await audio.dispose();
  });

  test(
    'dispose returns while initialization is pending and never starts audio',
    () async {
      final output = _Output()..loadGate = Completer<void>();
      final audio = _audio(output);
      final opening = audio.initialize();
      audio.setActive(true);
      audio.update(listenerPosition: vm.Vector3.zero(), listenerYaw: 0);
      await audio.dispose();
      output.loadGate!.complete();
      await opening;
      await _flush();
      expect(output.plays, isEmpty);
      expect(audio.available, isFalse);
    },
  );

  test('a stalled output fails softly with a bounded wait', () async {
    final output = _Output()..loadGate = Completer<void>();
    final audio = _audio(output, timeout: const Duration(milliseconds: 5));
    await audio.initialize();
    expect(audio.failureReason, 'audio-unavailable');
    expect(audio.available, isFalse);
    output.loadGate!.complete();
    await audio.dispose();
  });

  test(
    'distance culls voices and a short one-shot is not restarted forever',
    () async {
      var time = Duration.zero;
      final output = _Output();
      final audio = _audio(
        output,
        now: () => time,
        emitters: [_e('once', 0, loop: false)],
      );
      await audio.initialize();
      audio.setActive(true);
      audio.update(listenerPosition: vm.Vector3.zero(), listenerYaw: 0);
      await _flush();
      time = const Duration(seconds: 2);
      audio.update(listenerPosition: vm.Vector3.zero(), listenerYaw: 0);
      await _flush();
      expect(output.active, isEmpty);
      time = const Duration(seconds: 3);
      audio.update(listenerPosition: vm.Vector3.zero(), listenerYaw: 0);
      await _flush();
      expect(output.plays, ['once']);
      await audio.dispose();
    },
  );

  test('invalid local bytes fail before the host output is loaded', () async {
    final output = _Output();
    final audio = VrlwWorldAudio(
      output: output,
      emitters: [_e('main', 0)],
      resources: {'ambient': Uint8List(44)},
    );
    await audio.initialize();
    expect(audio.failureReason, 'invalid-audio');
    expect(output.loads, 0);
    await audio.dispose();
  });
}

VrlwAudioEmitter _e(String id, double x, {bool loop = true}) =>
    VrlwAudioEmitter(
      id: id,
      resource: 'ambient',
      x: x,
      y: 0,
      z: 0,
      maxDistance: 30,
      loop: loop,
    );

VrlwWorldAudio _audio(
  _Output output, {
  List<VrlwAudioEmitter>? emitters,
  Duration Function()? now,
  double masterGain = .2,
  Duration? timeout,
}) => VrlwWorldAudio(
  output: output,
  emitters: emitters ?? [_e('main', 0)],
  resources: {'ambient': _wav()},
  now: now,
  masterGain: masterGain,
  operationTimeout: timeout ?? const Duration(seconds: 5),
);

Future<void> _flush() => Future<void>.delayed(Duration.zero);

final class _Output implements VrlwAudioOutput {
  Completer<void>? loadGate, playGate;
  int loads = 0, updates = 0;
  final plays = <String>[];
  final stops = <String>[];
  final active = <String, (double, double)>{};
  @override
  Future<void> load(String resourceId, Uint8List wav) async {
    loads++;
    await loadGate?.future;
  }

  @override
  Future<void> play(
    String emitterId,
    String resourceId, {
    required bool loop,
    required double gain,
    required double pan,
  }) async {
    plays.add(emitterId);
    await playGate?.future;
    active[emitterId] = (gain, pan);
  }

  @override
  Future<void> update(
    String emitterId, {
    required double gain,
    required double pan,
  }) async {
    updates++;
    active[emitterId] = (gain, pan);
  }

  @override
  Future<void> stop(String emitterId) async {
    stops.add(emitterId);
    active.remove(emitterId);
  }

  @override
  Future<void> stopAll() async => active.clear();
  @override
  Future<void> dispose() async => active.clear();
}

Uint8List _wav({int rate = 16000, int seconds = 1}) {
  final bytes = Uint8List(44 + rate * seconds * 2);
  final d = ByteData.sublistView(bytes);
  d.setUint32(0, 0x46464952, Endian.little);
  d.setUint32(4, bytes.length - 8, Endian.little);
  d.setUint32(8, 0x45564157, Endian.little);
  d.setUint32(12, 0x20746d66, Endian.little);
  d.setUint32(16, 16, Endian.little);
  d.setUint16(20, 1, Endian.little);
  d.setUint16(22, 1, Endian.little);
  d.setUint32(24, rate, Endian.little);
  d.setUint32(28, rate * 2, Endian.little);
  d.setUint16(32, 2, Endian.little);
  d.setUint16(34, 16, Endian.little);
  d.setUint32(36, 0x61746164, Endian.little);
  d.setUint32(40, bytes.length - 44, Endian.little);
  return bytes;
}
