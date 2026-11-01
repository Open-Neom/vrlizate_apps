import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_apps/src/viewer/vrlw_scene_adapter.dart';
import 'package:vrlizate_apps/vrlizate_apps.dart';
import 'package:vrlizate_world/vrlizate_world.dart';

import 'support/vrlz_world_fixture.dart';

void main() {
  final unsupportedTexture = throwsA(
    isA<FormatException>().having(
      (error) => error.message,
      'message',
      contains('cannot decode texture.ktx2'),
    ),
  );

  VrlzWorldBundle bundle({bool sky = false, bool environment = false}) {
    // A valid container envelope; the mobile decoder policy must run before
    // any GPU decoder attempts to interpret the KTX2 payload itself.
    final bytes = Uint8List(80)
      ..setRange(0, 12, [
        0xab,
        0x4b,
        0x54,
        0x58,
        0x20,
        0x32,
        0x30,
        0xbb,
        0x0d,
        0x0a,
        0x1a,
        0x0a,
      ]);
    ByteData.sublistView(bytes)
      ..setUint32(20, 1, Endian.little)
      ..setUint32(24, 1, Endian.little);
    final fixture = worldFixture(
      changeWorld: (source) {
        source['resources'][1]['type'] = environment
            ? 'environment.ktx2'
            : 'texture.ktx2';
        source['resources'][1]['data'] = base64Encode(bytes);
        if (environment) {
          source['resources'][1].remove('width');
          source['resources'][1].remove('height');
        }
        if (sky || environment) {
          source['prototypeBindings'][0].remove('baseColorTexture');
          source['environment'] = {
            if (sky) 'skyboxResource': 'floor.color',
            if (environment) 'environmentResource': 'floor.color',
          };
        }
      },
    );
    return VrlzWorldBundle.decode(
      VrlzWorldBundle.encode(fixture.manifest, fixture.files),
    );
  }

  test(
    'material KTX2 fails during preparation with a precise export remedy',
    () async {
      await expectLater(bundle().openWorld('garden'), unsupportedTexture);
    },
  );

  test(
    'panorama KTX2 fails during preparation before scene initialization',
    () async {
      await expectLater(
        bundle(sky: true).openWorld('garden'),
        unsupportedTexture,
      );
    },
  );

  test(
    'direct adapter callers also fail before creating native GPU resources',
    () async {
      final reader = await VrlwPlaceReader.open(
        VrlwMemorySource(bundle(sky: true).worldBytes('garden')),
        registeredPrototypeIds: {'test.floor'},
      );
      addTearDown(reader.close);
      await expectLater(
        VrlwSceneAdapter.create(reader, {}, isCurrent: () => true),
        unsupportedTexture,
      );
    },
  );

  test(
    'IBL KTX2 remains allowed by preparation for its dedicated GPU decoder',
    () async {
      final prepared = await bundle(environment: true).openWorld('garden');
      addTearDown(prepared.reader.close);
      expect(prepared.resources.containsKey('floor.color'), isTrue);
    },
  );
}
