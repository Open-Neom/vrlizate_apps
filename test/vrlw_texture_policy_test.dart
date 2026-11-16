import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_apps/src/bundles/vrlw_texture_policy.dart';
import 'package:vrlizate_apps/src/viewer/vrlw_scene_adapter.dart';
import 'package:vrlizate_apps/src/viewer/vrlw_skybox.dart';
import 'package:vrlizate_apps/vrlizate_apps.dart';
import 'package:vrlizate_scene/vrlizate_scene.dart'
    show VrKtx2Codec, VrRawMipLevel;
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

  test(
    'v2 worlds admit valid 2D texture.ktx2 and account compressed VRAM',
    () async {
      final rgba = Uint8List(16 * 16 * 4)..fillRange(0, 16 * 16 * 4, 220);
      final validKtx2 = VrKtx2Codec.encodeMipChainToKtx2(<VrRawMipLevel>[
        VrRawMipLevel(width: 16, height: 16, rgba: rgba),
      ]);
      final fixture = worldFixture(
        changeWorld: (source) {
          source['resources'][1] = <String, Object>{
            'id': 'floor.color',
            'type': 'texture.ktx2',
            'width': 16,
            'height': 16,
            'data': base64Encode(validKtx2),
          };
        },
      );
      fixture.manifest['formatVersion'] = 2;
      fixture.manifest['runtime'] = VrlzWorldManifest.runtimeV2;
      fixture.manifest['capabilities'] = const <String>[
        'worlds.local',
        'worlds.ktx2',
      ];
      final v2Bundle = VrlzWorldBundle.decode(
        VrlzWorldBundle.encode(fixture.manifest, fixture.files),
      );
      final metrics = v2Bundle.inspectBudgetMetrics();
      expect(metrics.peakVramBytes, greaterThan(0));

      final prepared = await v2Bundle.openWorld('garden');
      addTearDown(prepared.reader.close);
      expect(prepared.isV2, isTrue);
      expect(prepared.resources['floor.color'], validKtx2);

      final sky = await loadVrlwAuthoredSky<String>(
        const VrlwEnvironmentSpec(skyboxResource: 'panorama'),
        allowKtx2Textures: true,
        resourceType: (_) => 'texture.ktx2',
        fromEnvironment: (_) async => throw StateError('Wrong decoder'),
        fromTexture: (id) async => 'ktx2-sky:$id',
      );
      expect(sky, 'ktx2-sky:panorama');
    },
  );

  test(
    'v2 worlds reject unsupported KTX2 formats or mismatched dimensions',
    () async {
      final rgba = Uint8List(16 * 16 * 4)..fillRange(0, 16 * 16 * 4, 200);
      final validKtx2 = VrKtx2Codec.encodeMipChainToKtx2(<VrRawMipLevel>[
        VrRawMipLevel(width: 16, height: 16, rgba: rgba),
      ]);
      expect(
        () => VrlwTexturePolicy.validateKtx2Payload(
          validKtx2,
          declaredWidth: 32,
          declaredHeight: 16,
        ),
        throwsFormatException,
      );

      // 80-byte stub KTX2 with vkFormat=0 and empty DFD is rejected in v2.
      final stubBytes = Uint8List(80)
        ..setRange(0, 12, VrKtx2Codec.ktx2Magic);
      ByteData.sublistView(stubBytes)
        ..setUint32(20, 1, Endian.little)
        ..setUint32(24, 1, Endian.little);
      final fixture = worldFixture(
        changeWorld: (source) {
          source['resources'][1] = <String, Object>{
            'id': 'floor.color',
            'type': 'texture.ktx2',
            'width': 1,
            'height': 1,
            'data': base64Encode(stubBytes),
          };
        },
      );
      fixture.manifest['formatVersion'] = 2;
      fixture.manifest['runtime'] = VrlzWorldManifest.runtimeV2;
      fixture.manifest['capabilities'] = const <String>[
        'worlds.local',
        'worlds.ktx2',
      ];
      final v2Bundle = VrlzWorldBundle.decode(
        VrlzWorldBundle.encode(fixture.manifest, fixture.files),
      );
      await expectLater(v2Bundle.openWorld('garden'), throwsFormatException);
    },
  );
}
