import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_apps/vrlizate_apps.dart';

import 'support/vrlz_world_fixture.dart';
import 'support/vrz_fixture.dart';

Uint8List _wav({int sampleRate = 16000, int frames = 1600}) {
  final bytes = Uint8List(44 + frames * 2);
  ByteData.sublistView(bytes)
    ..setUint32(0, 0x46464952, Endian.little)
    ..setUint32(4, bytes.length - 8, Endian.little)
    ..setUint32(8, 0x45564157, Endian.little)
    ..setUint32(12, 0x20746d66, Endian.little)
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little)
    ..setUint16(22, 1, Endian.little)
    ..setUint32(24, sampleRate, Endian.little)
    ..setUint32(28, sampleRate * 2, Endian.little)
    ..setUint16(32, 2, Endian.little)
    ..setUint16(34, 16, Endian.little)
    ..setUint32(36, 0x61746164, Endian.little)
    ..setUint32(40, frames * 2, Endian.little);
  return bytes;
}

({Map<String, dynamic> manifest, Map<String, Uint8List> files}) _fixture({
  int modelCount = 1,
  List<Uint8List>? audio,
  String audioType = 'audio.wav',
  void Function(Map<String, dynamic>)? changeJson,
}) {
  final sounds = audio ?? [_wav()];
  final model = triangleGlb(
    changeJson: (doc) {
      doc['nodes'][0]['name'] = 'rotor';
      changeJson?.call(doc);
    },
  );
  return worldFixture(
    model: model,
    changeWorld: (source) {
      source['prototypes'] = List.generate(modelCount, (i) => 'model-$i');
      source['resources'] = [
        for (var n = 0; n < modelCount; n++)
          {'id': 'mesh-$n', 'type': 'model.glb', 'data': base64Encode(model)},
        for (var n = 0; n < sounds.length; n++)
          {
            'id': 'sound-$n',
            'type': audioType,
            'data': base64Encode(sounds[n]),
          },
      ];
      source['prototypeBindings'] = [
        for (var n = 0; n < modelCount; n++)
          {'prototypeId': 'model-$n', 'model': 'mesh-$n'},
      ];
      source['regions'][0]['entities'][0]['prototypeId'] = 'model-0';
      source['motions'] = [
        {
          'id': 'spin',
          'prototypeId': 'model-0',
          'node': 'rotor',
          'kind': 'spin',
          'axis': 'y',
          'periodSeconds': 8,
        },
      ];
      source['audioEmitters'] = [
        for (var n = 0; n < sounds.length; n++)
          {'id': 'emitter-$n', 'resource': 'sound-$n', 'x': 2, 'y': 1, 'z': 2},
      ];
      source['interactions'] = [
        {
          'id': 'spin-switch',
          'label': 'Rotor',
          'position': [2, 1, 2],
          'action': 'toggleMotion',
          'target': 'spin',
        },
        if (sounds.isNotEmpty)
          {
            'id': 'audio-switch',
            'label': 'Sonido',
            'position': [2, 1, 2],
            'action': 'toggleAudio',
            'target': 'emitter-0',
          },
      ];
    },
  );
}

VrlzWorldBundle _bundle(
  ({Map<String, dynamic> manifest, Map<String, Uint8List> files}) fixture,
) => VrlzWorldBundle.decode(
  VrlzWorldBundle.encode(fixture.manifest, fixture.files),
);

void main() {
  test(
    'eight model resources plus one bounded PCM prepare before GPU registration',
    () async {
      final fixture = _fixture(modelCount: 8);
      final bundle = _bundle(fixture);
      final prepared = await bundle.openWorld('garden');
      try {
        expect(prepared.resources, hasLength(9));
        expect(prepared.reader.registeredPrototypeIds, hasLength(8));
        expect(prepared.reader.index.motions.single.node, 'rotor');
        expect(prepared.reader.index.interactions, hasLength(2));
        expect(
          VrlwAudioPolicy.validate(prepared.resources['sound-0']!).frameCount,
          1600,
        );
      } finally {
        await prepared.reader.close();
      }
      final raw = VrlzWorldBundle.fromRawVrlw(
        fixture.files['world_garden.vrlw']!,
      );
      final rawPrepared = await raw.openWorld('main');
      await rawPrepared.reader.close();
    },
  );

  test('ninth model is not admitted by the separate audio allowance', () {
    final fixture = _fixture(modelCount: 9);
    expect(() => _bundle(fixture), throwsFormatException);
    expect(
      () => VrlzWorldBundle.fromRawVrlw(fixture.files['world_garden.vrlw']!),
      throwsFormatException,
    );
  });

  test(
    'second WAV is rejected even when there are fewer than eight models',
    () {
      final fixture = _fixture(audio: [_wav(), _wav()]);
      expect(() => _bundle(fixture), throwsFormatException);
    },
  );

  test('compressed Ogg is outside the initial portable ambient profile', () {
    final ogg = Uint8List(28);
    ByteData.sublistView(ogg).setUint32(0, 0x5367674f, Endian.little);
    expect(
      () => _bundle(_fixture(audio: [ogg], audioType: 'audio.ogg')),
      throwsFormatException,
    );
  });

  test('over-budget WAV is rejected before opening or decoding resources', () {
    final fixture = _fixture(audio: [_wav(frames: 140000)]);
    expect(() => _bundle(fixture), throwsFormatException);
  });

  final malformedNodes = <String, void Function(Map<String, dynamic>)>{
    'missing named node': (d) => d['nodes'][0]['name'] = 'not-the-rotor',
    'duplicate name in active scene': (d) {
      d['nodes'].add({'name': 'rotor', 'mesh': 0});
      d['scenes'][0]['nodes'].add(1);
    },
    'duplicate name in inactive node': (d) =>
        d['nodes'].add({'name': 'rotor', 'mesh': 0}),
    'translated node': (d) => d['nodes'][0]['translation'] = [1, 0, 0],
    'scaled node': (d) => d['nodes'][0]['scale'] = [2, 2, 2],
    'rotated node': (d) => d['nodes'][0]['rotation'] = [0, 1, 0, 0],
    'matrix node': (d) => d['nodes'][0]['matrix'] = [
      1,
      0,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      1,
      0,
      1,
      0,
      0,
      1,
    ],
    'node with child': (d) {
      d['nodes'][0]['children'] = [1];
      d['nodes'].add({'mesh': 0});
    },
    'mesh under transformed parent': (d) {
      d['nodes'].add({
        'children': [0],
        'translation': [1, 0, 0],
      });
      d['scenes'][0]['nodes'] = [1];
    },
    'named leaf only in inactive scene': (d) {
      d['nodes'].add({'mesh': 0});
      d['scenes'].add({
        'nodes': [1],
      });
      d['scene'] = 1;
    },
    'named leaf without mesh': (d) {
      d['nodes'][0].remove('mesh');
      d['nodes'].add({'mesh': 0});
      d['scenes'][0]['nodes'].add(1);
    },
  };
  for (final entry in malformedNodes.entries) {
    test(
      'named motion profile rejects ${entry.key} before GPU import',
      () async {
        final fixture = _fixture(changeJson: entry.value);
        final bundle = _bundle(fixture);
        await expectLater(bundle.openWorld('garden'), throwsFormatException);
      },
    );
  }

  test(
    'PCM accepts both supported rates and reports exact bounded duration',
    () {
      for (final rate in [16000, 22050]) {
        final result = VrlwAudioPolicy.validate(
          _wav(sampleRate: rate, frames: rate),
        );
        expect(result.sampleRate, rate);
        expect(result.frameCount, rate);
        expect(result.duration, const Duration(seconds: 1));
      }
      expect(
        VrlwAudioPolicy.validate(_wav(frames: 128000)).duration,
        const Duration(seconds: 8),
      );
    },
  );

  final malformedPcm = <String, void Function(ByteData)>{
    'RIFF length mismatch': (d) => d.setUint32(4, 100, Endian.little),
    'extended fmt payload': (d) => d.setUint32(16, 18, Endian.little),
    'float format': (d) => d.setUint16(20, 3, Endian.little),
    'stereo channels': (d) => d.setUint16(22, 2, Endian.little),
    'unsupported rate': (d) => d.setUint32(24, 48000, Endian.little),
    'inconsistent byte rate': (d) => d.setUint32(28, 123, Endian.little),
    'incorrect block alignment': (d) => d.setUint16(32, 4, Endian.little),
    '8-bit PCM': (d) => d.setUint16(34, 8, Endian.little),
    'missing data chunk': (d) => d.setUint32(36, 0x4b4e554a, Endian.little),
    'empty PCM': (d) => d.setUint32(40, 0, Endian.little),
    'inconsistent data length': (d) => d.setUint32(40, 2, Endian.little),
    'odd sample data length': (d) => d.setUint32(40, 3199, Endian.little),
  };
  for (final entry in malformedPcm.entries) {
    test('invalid PCM ${entry.key} never produces a prepared world', () async {
      final wav = _wav();
      entry.value(ByteData.sublistView(wav));
      final bundle = _bundle(_fixture(audio: [wav]));
      await expectLater(bundle.openWorld('garden'), throwsFormatException);
    });
  }

  test(
    'over eight seconds fails even if bytes remain below the WAV cap',
    () async {
      final wav = _wav(frames: 128001);
      expect(wav.length, lessThan(VrlwAudioPolicy.maxBytes));
      final bundle = _bundle(_fixture(audio: [wav]));
      await expectLater(bundle.openWorld('garden'), throwsFormatException);
    },
  );
}
