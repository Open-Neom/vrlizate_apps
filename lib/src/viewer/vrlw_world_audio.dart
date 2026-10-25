import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math.dart' as vm;
import 'package:vrlizate_scene/vrlizate_scene.dart'
    show VrSpatialAudioEvaluator;
import 'package:vrlizate_world/vrlizate_world.dart';

import '../bundles/vrlw_audio_policy.dart';

/// The host owns native playback; this SDK never creates a second audio engine.
abstract interface class VrlwAudioOutput {
  Future<void> load(String resourceId, Uint8List wav);
  Future<void> play(
    String emitterId,
    String resourceId, {
    required bool loop,
    required double gain,
    required double pan,
  });
  Future<void> update(
    String emitterId, {
    required double gain,
    required double pan,
  });
  Future<void> stop(String emitterId);
  Future<void> stopAll();
  Future<void> dispose();
}

/// Two bounded local voices with head-relative stereo balance, not HRTF.
/// Starts inactive: a current, visible host must explicitly activate playback.
/// Updates are coalesced and sampled at 10Hz; inactive/disabled stops immediately.
final class VrlwWorldAudio {
  VrlwWorldAudio({
    required VrlwAudioOutput output,
    required List<VrlwAudioEmitter> emitters,
    required Map<String, Uint8List> resources,
    bool enabled = true,
    this.masterGain = .2,
    this.operationTimeout = const Duration(seconds: 5),
    Duration Function()? now,
  }) : _output = output,
       _emitters = List.unmodifiable(emitters),
       _resources = Map.unmodifiable(resources),
       _enabled = enabled,
       _now = now {
    if (!masterGain.isFinite ||
        masterGain < 0 ||
        masterGain > 1 ||
        operationTimeout <= Duration.zero ||
        operationTimeout > const Duration(seconds: 15)) {
      throw ArgumentError('Use a bounded ambient master gain.');
    }
  }

  static const maxVoices = 2;
  static const mixInterval = Duration(milliseconds: 100);
  final VrlwAudioOutput _output;
  final List<VrlwAudioEmitter> _emitters;
  final Map<String, Uint8List> _resources;
  final Duration Function()? _now;
  final double masterGain;
  final Duration operationTimeout;
  final _clock = Stopwatch()..start();
  final _disabled = <String>{};
  final _playing = <String, _Mix>{};
  final _startedUs = <String, int>{};
  final _playedOneShots = <String>{};
  final _durationsUs = <String, int>{};
  List<_Mix> _desired = const [];
  vm.Vector3? _listener;
  double _listenerYaw = 0;
  int _revision = 0;
  int? _lastMixUs;
  bool _enabled, _active = false, _ready = false, _failed = false;
  bool _disposed = false, _dirty = false, _draining = false;
  String? _failureReason;
  Future<void>? _initializing, _disposing;

  bool get enabled => _enabled;
  bool get available => _ready && !_failed && !_disposed;
  String? get failureReason => _failureReason;
  bool isEmitterEnabled(String id) => !_disabled.contains(id);
  int get _timeUs => (_now?.call() ?? _clock.elapsed).inMicroseconds;

  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    if (_disposed) return;
    try {
      final ids = <String>{};
      final resources = <String>{};
      if (_emitters.length > 64) throw const FormatException('Emitter limit.');
      for (final e in _emitters) {
        if (!ids.add(e.id) ||
            ![
              e.x,
              e.y,
              e.z,
              e.volume,
              e.maxDistance,
            ].every((n) => n.isFinite) ||
            e.volume < 0 ||
            e.volume > 1 ||
            e.maxDistance < .1 ||
            e.maxDistance > 500) {
          throw const FormatException('Invalid ambient emitter.');
        }
        resources.add(e.resource);
      }
      if (resources.length > 1) {
        throw const FormatException('Audio resource limit.');
      }
      for (final id in resources) {
        final bytes = _resources[id];
        if (bytes == null) {
          throw const FormatException('Missing ambient resource.');
        }
        final info = VrlwAudioPolicy.validate(bytes);
        _durationsUs[id] = info.duration.inMicroseconds;
        await _bounded(_output.load(id, bytes));
        if (_disposed) return;
      }
      _ready = true;
      _mix(force: true);
    } on FormatException {
      _fail('invalid-audio');
    } catch (_) {
      _fail('audio-unavailable');
    }
  }

  void update({
    required vm.Vector3 listenerPosition,
    required double listenerYaw,
  }) {
    if (_disposed || _failed) return;
    if (![
      listenerPosition.x,
      listenerPosition.y,
      listenerPosition.z,
      listenerYaw,
    ].every((n) => n.isFinite)) {
      _suspend();
      return;
    }
    (_listener ??= vm.Vector3.zero()).setFrom(listenerPosition);
    _listenerYaw = listenerYaw;
    _mix();
  }

  void setActive(bool active) {
    if (_disposed || _active == active) return;
    _active = active;
    if (!active) {
      _suspend();
    } else {
      _mix(force: true);
    }
  }

  void setEnabled(bool enabled) {
    if (_disposed || _enabled == enabled) return;
    _enabled = enabled;
    if (!enabled) {
      _suspend();
    } else {
      _mix(force: true);
    }
  }

  void setEmitterEnabled(String id, bool enabled) {
    if (_disposed || !_emitters.any((e) => e.id == id)) return;
    final changed = enabled ? _disabled.remove(id) : _disabled.add(id);
    if (changed) _mix(force: true);
  }

  void _mix({bool force = false}) {
    if (_disposed ||
        _failed ||
        !_ready ||
        !_active ||
        !_enabled ||
        _listener == null) {
      return;
    }
    final time = _timeUs;
    if (!force &&
        _lastMixUs != null &&
        time - _lastMixUs! < mixInterval.inMicroseconds) {
      return;
    }
    _lastMixUs = time;
    final candidates = <_Mix>[];
    for (final e in _emitters) {
      if (_disabled.contains(e.id)) continue;
      if (!e.loop && _playedOneShots.contains(e.id)) {
        final started = _startedUs[e.id];
        if (started == null || time - started >= _durationsUs[e.resource]!) {
          continue;
        }
      }
      final (gain, pan) = VrSpatialAudioEvaluator.evaluate(
        source: vm.Vector3(e.x, e.y, e.z),
        listener: _listener!,
        listenerYaw: _listenerYaw,
        minDistance: math.min(1, e.maxDistance * .5),
        maxDistance: e.maxDistance,
      );
      final level = gain * e.volume;
      if (level >= .001) candidates.add(_Mix(e, level, pan));
    }
    candidates.sort((a, b) {
      final gain = b.gain.compareTo(a.gain);
      return gain != 0 ? gain : a.emitter.id.compareTo(b.emitter.id);
    });
    final audible = candidates.take(maxVoices).toList();
    final sum = audible.fold<double>(0, (value, mix) => value + mix.gain);
    final scale = masterGain / math.max(1.0, sum);
    _desired = [
      for (final mix in audible)
        _Mix(mix.emitter, (mix.gain * scale).clamp(0.0, 1.0), mix.pan),
    ];
    _revision++;
    _dirty = true;
    _schedule();
  }

  bool _current(int revision) =>
      !_disposed && !_failed && revision == _revision;
  Future<void> _bounded(Future<void> task) => task.timeout(operationTimeout);

  void _schedule() {
    if (_draining || _disposed || _failed) return;
    _draining = true;
    unawaited(_drain());
  }

  Future<void> _drain() async {
    try {
      while (_dirty && !_disposed && !_failed) {
        _dirty = false;
        final revision = _revision;
        final target = List<_Mix>.of(_desired);
        final wanted = {for (final mix in target) mix.emitter.id};
        for (final id in _playing.keys.toList()) {
          if (!_current(revision)) break;
          if (!wanted.contains(id)) {
            _playing.remove(id);
            _startedUs.remove(id);
            await _bounded(_output.stop(id));
          }
        }
        for (final mix in target) {
          if (!_current(revision)) break;
          final id = mix.emitter.id;
          final previous = _playing[id];
          if (previous == null) {
            await _bounded(
              _output.play(
                id,
                mix.emitter.resource,
                loop: mix.emitter.loop,
                gain: mix.gain,
                pan: mix.pan,
              ),
            );
            if (!_current(revision)) {
              await _bounded(_output.stop(id));
              break;
            }
            _startedUs[id] = _timeUs;
            if (!mix.emitter.loop) _playedOneShots.add(id);
          } else if ((previous.gain - mix.gain).abs() >= .005 ||
              (previous.pan - mix.pan).abs() >= .015) {
            await _bounded(_output.update(id, gain: mix.gain, pan: mix.pan));
            if (!_current(revision)) break;
          } else {
            // Compare against the last applied native value, so small changes
            // accumulate rather than disappearing at every 100ms sample.
            continue;
          }
          _playing[id] = mix;
        }
      }
    } catch (_) {
      _fail('audio-unavailable');
    } finally {
      _draining = false;
      if (_dirty && !_disposed && !_failed) _schedule();
    }
  }

  void _suspend() {
    _revision++;
    _desired = const [];
    _playing.clear();
    _startedUs.clear();
    _lastMixUs = null;
    _dirty = true;
    _ignore(_output.stopAll());
  }

  void _ignore(Future<void> task) {
    unawaited(
      _bounded(task).catchError((Object _) => _fail('audio-unavailable')),
    );
  }

  void _fail(String reason) {
    if (_disposed || _failed) return;
    _failed = true;
    _failureReason = reason;
    _revision++;
    _desired = const [];
    _playing.clear();
    unawaited(_bounded(_output.stopAll()).catchError((Object _) {}));
  }

  Future<void> dispose() => _disposing ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    _revision++;
    _desired = const [];
    _playing.clear();
    _clock.stop();
    try {
      await _bounded(_output.dispose());
    } catch (_) {
      // No native audio failure can retain a world or stop scene disposal.
    }
  }
}

final class _Mix {
  const _Mix(this.emitter, this.gain, this.pan);
  final VrlwAudioEmitter emitter;
  final double gain, pan;
}
