import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vector_math/vector_math.dart' as vm;
import 'package:vrlizate_apps/src/viewer/vrlw_scene_adapter.dart';
import 'package:vrlizate_apps/vrlizate_apps.dart';
import 'package:vrlizate_physics/vrlizate_physics.dart';
import 'package:vrlizate_world/vrlizate_world.dart';

import 'support/retro_fixture.dart';
import 'support/vrlz_world_fixture.dart';
import 'support/vrz_fixture.dart';

Uint8List _fakeKtx2Header(int width, int height) {
  final bytes = Uint8List(80);
  const magic = <int>[
    0xAB,
    0x4B,
    0x54,
    0x58,
    0x20,
    0x32,
    0x30,
    0xBB,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
  ];
  bytes.setRange(0, magic.length, magic);
  final view = ByteData.sublistView(bytes);
  view.setUint32(20, width, Endian.little);
  view.setUint32(24, height, Endian.little);
  view.setUint32(28, 0, Endian.little); // depth = 0 (2D)
  view.setUint32(36, 1, Endian.little); // faceCount = 1
  view.setUint32(40, 1, Endian.little); // levelCount = 1
  return bytes;
}

Uint8List _v2ShowcaseGlb({int ktxWidth = 512, int ktxHeight = 512}) {
  final ktx = _fakeKtx2Header(ktxWidth, ktxHeight);
  // Layout in BIN:
  // 0..35: 3 VEC3 positions (36 bytes)
  // 36..59: 3 VEC2 TEXCOORD_0 (24 bytes)
  // 60..83: 3 VEC2 TEXCOORD_1 (24 bytes)
  // 84..91: 2 SCALAR animation times [0.0, 1.0] (8 bytes)
  // 92..115: 2 VEC3 animation translations (24 bytes)
  // 116..195: 80-byte KTX2 image
  final bin = Uint8List(116 + ktx.length);
  final data = ByteData.sublistView(bin);
  final positions = <double>[0, 0, 0, 1, 0, 0, 0, 1, 0];
  for (var i = 0; i < positions.length; i++) {
    data.setFloat32(i * 4, positions[i], Endian.little);
  }
  final uvs = <double>[0, 0, 1, 0, 0, 1];
  for (var i = 0; i < uvs.length; i++) {
    data.setFloat32(36 + i * 4, uvs[i], Endian.little);
    data.setFloat32(60 + i * 4, uvs[i], Endian.little);
  }
  data.setFloat32(84, 0.0, Endian.little);
  data.setFloat32(88, 1.0, Endian.little);
  final animOut = <double>[0, 0, 0, 0, 0.5, 0];
  for (var i = 0; i < animOut.length; i++) {
    data.setFloat32(92 + i * 4, animOut[i], Endian.little);
  }
  bin.setRange(116, 116 + ktx.length, ktx);

  final json = <String, Object?>{
    'asset': {'version': '2.0'},
    'extensionsUsed': [
      'KHR_texture_basisu',
      'KHR_materials_emissive_strength',
      'KHR_texture_transform',
    ],
    'extensionsRequired': ['KHR_texture_basisu'],
    'buffers': [
      {'byteLength': bin.length},
    ],
    'bufferViews': [
      {'buffer': 0, 'byteOffset': 0, 'byteLength': 36},
      {'buffer': 0, 'byteOffset': 36, 'byteLength': 24},
      {'buffer': 0, 'byteOffset': 60, 'byteLength': 24},
      {'buffer': 0, 'byteOffset': 84, 'byteLength': 8},
      {'buffer': 0, 'byteOffset': 92, 'byteLength': 24},
      {'buffer': 0, 'byteOffset': 116, 'byteLength': ktx.length},
    ],
    'accessors': [
      {'bufferView': 0, 'componentType': 5126, 'count': 3, 'type': 'VEC3'},
      {'bufferView': 1, 'componentType': 5126, 'count': 3, 'type': 'VEC2'},
      {'bufferView': 2, 'componentType': 5126, 'count': 3, 'type': 'VEC2'},
      {'bufferView': 3, 'componentType': 5126, 'count': 2, 'type': 'SCALAR'},
      {'bufferView': 4, 'componentType': 5126, 'count': 2, 'type': 'VEC3'},
    ],
    'images': [
      {'bufferView': 5, 'mimeType': 'image/ktx2'},
    ],
    'samplers': [
      {'magFilter': 9729, 'minFilter': 9987},
    ],
    'textures': [
      {
        'sampler': 0,
        'extensions': {
          'KHR_texture_basisu': {'source': 0},
        },
      },
    ],
    'materials': [
      {
        'pbrMetallicRoughness': {
          'baseColorFactor': [1, 1, 1, 1],
          'metallicFactor': 0.2,
          'roughnessFactor': 0.6,
          'baseColorTexture': {
            'index': 0,
            'texCoord': 0,
            'extensions': {
              'KHR_texture_transform': {
                'scale': [2.0, 2.0],
              },
            },
          },
          'metallicRoughnessTexture': {'index': 0, 'texCoord': 0},
        },
        'normalTexture': {'index': 0, 'scale': 1.0},
        'occlusionTexture': {'index': 0, 'texCoord': 1, 'strength': 0.85},
        'emissiveTexture': {'index': 0},
        'emissiveFactor': [0.4, 0.7, 1.0],
        'extensions': {
          'KHR_materials_emissive_strength': {'emissiveStrength': 3.5},
        },
      },
    ],
    'meshes': [
      {
        'primitives': [
          {
            'attributes': {'POSITION': 0, 'TEXCOORD_0': 1, 'TEXCOORD_1': 2},
            'material': 0,
          },
        ],
      },
    ],
    'nodes': [
      {'name': 'hero', 'mesh': 0},
    ],
    'animations': [
      {
        'name': 'Float',
        'samplers': [
          {'input': 3, 'output': 4, 'interpolation': 'LINEAR'},
        ],
        'channels': [
          {
            'sampler': 0,
            'target': {'node': 0, 'path': 'translation'},
          },
        ],
      },
    ],
    'scenes': [
      {
        'nodes': [0],
      },
    ],
    'scene': 0,
  };

  final metadata = utf8.encode(jsonEncode(json));
  final aligned = (metadata.length + 3) & ~3;
  final out = Uint8List(12 + 8 + aligned + 8 + bin.length);
  final header = ByteData.sublistView(out);
  header.setUint32(0, 0x46546c67, Endian.little);
  header.setUint32(4, 2, Endian.little);
  header.setUint32(8, out.length, Endian.little);
  header.setUint32(12, aligned, Endian.little);
  header.setUint32(16, 0x4e4f534a, Endian.little);
  out.fillRange(20, 20 + aligned, 32);
  out.setRange(20, 20 + metadata.length, metadata);
  header.setUint32(20 + aligned, bin.length, Endian.little);
  header.setUint32(24 + aligned, 0x004e4942, Endian.little);
  out.setRange(28 + aligned, out.length, bin);
  return out;
}

void main() {
  test(
    'scene.v2 admits KTX2 BasisU, PBR maps, TEXCOORD_1 and animations while v1 stays strict',
    () {
      final glb = _v2ShowcaseGlb(ktxWidth: 512, ktxHeight: 512);
      // v1 rejects KTX2/animations/PBR maps.
      expect(
        () => VrzBundle.encode(
          sceneBytes: glb,
          id: 'org.example.strict_v1',
          title: 'Strict V1',
        ),
        throwsFormatException,
      );

      final encoded = VrlzPackage.encodeSceneV2(
        sceneBytes: glb,
        id: 'org.example.showcase_v2',
        title: 'Showcase V2',
        description: 'PBR + KTX2 + Animation',
        capabilities: const [
          'scene.gltf2',
          'scene.pbr',
          'scene.ktx2',
          'scene.animation',
          'scene.lightmap',
        ],
        extensions: const {
          'vrlizate.graphics': {'tonemap': 'pbrNeutral'},
        },
      );
      final pkg = VrlzPackage.decode(encoded);
      expect(pkg.kind, VrlzPackageKind.scene);
      expect(pkg.isCreatorSubmittable, isTrue);
      expect(pkg.sceneBundle!.manifest.isV2, isTrue);
      expect(pkg.sceneBundle!.manifest.formatVersion, 2);
      expect(pkg.sceneBundle!.manifest.runtime, VrzManifest.supportedRuntimeV2);
      expect(
        pkg.sceneBundle!.manifest.extensions['vrlizate.graphics'],
        isA<Map<String, Object?>>(),
      );
      // 4 material slots sharing 1 KTX2 512x512 GPU texture upload once!
      const perTexKtxVram = (512 * 512 * 4 + 2) ~/ 3;
      expect(pkg.sceneBundle!.glbStats.submittedTriangles, 1);
      expect(pkg.sceneBundle!.glbStats.estimatedVramBytes, perTexKtxVram);

      final roundtrip = VrlzPackage.decode(pkg.encode());
      expect(roundtrip.sceneBundle!.manifest.isV2, isTrue);
      expect(roundtrip.sceneBundle!.sceneBytes, glb);
    },
  );

  test(
    'worlds.v2 and raw .vrlw support >8 resources and collider wiring into PhysicsWorldSpace',
    () async {
      Uint8List? capturedRawVrlw;
      final fixture = worldFixture(
        worldAliases: const ['garden'],
        changeWorld: (world) {
          final resources = world['resources'] as List<dynamic>;
          for (var i = 0; i < 10; i++) {
            resources.add({
              'id': 'extra.tex.$i',
              'type': 'texture.rgba8',
              'width': 2,
              'height': 2,
              'data': base64Encode(List<int>.filled(16, 200)),
            });
          }
          final existingBinding = Map<String, dynamic>.from(
            (world['prototypeBindings'] as List<dynamic>).single
                as Map<Object?, Object?>,
          );
          existingBinding['collider'] = {
            'shape': 'box',
            'halfExtents': [2.0, 0.5, 2.0],
            'offset': [0.0, 0.5, 0.0],
          };
          world['prototypeBindings'] = <Map<String, dynamic>>[existingBinding];
        },
      );
      capturedRawVrlw = fixture.files['world_garden.vrlw']!;

      // v1 manifest with 12 non-audio resources is rejected.
      fixture.manifest['portals'] = const <Map<String, dynamic>>[];
      expect(
        () => VrlzWorldBundle.encode(fixture.manifest, fixture.files),
        throwsFormatException,
      );

      // Upgrading manifest to vrlizate.worlds.v2 succeeds and opens cleanly!
      final v2Manifest = <String, dynamic>{
        ...fixture.manifest,
        'formatVersion': 2,
        'runtime': VrlzWorldManifest.runtimeV2,
        'capabilities': ['worlds.local', 'worlds.pbr', 'worlds.physics'],
      };
      final encodedV2 = VrlzWorldBundle.encode(v2Manifest, fixture.files);
      final pkg = VrlzPackage.decode(encodedV2);
      expect(pkg.kind, VrlzPackageKind.worlds);
      expect(pkg.worldBundle!.manifest.isV2, isTrue);
      final prepared = await pkg.worldBundle!.openWorld('garden');
      addTearDown(prepared.reader.close);
      expect(prepared.isV2, isTrue);
      expect(prepared.resources.length, 12);

      // Raw .vrlw with >8 resources promotes automatically to worlds.v2 and
      // normalizes into a budgeted creator .vrlz archive!
      final creatorPkg = VrCreatorPackage.validate(capturedRawVrlw);
      expect(creatorPkg.package.kind, VrlzPackageKind.worlds);
      expect(creatorPkg.package.worldBundle!.manifest.isV2, isTrue);
      expect(creatorPkg.budget.withinLimits, isTrue);
      expect(creatorPkg.budget.entryCount, 1);

      // Verify collider spec converts cleanly into PhysicsWorldSpace and blocks/steps!
      final spec = prepared.reader.index.prototypeBindings.single.collider!;
      final space = PhysicsWorldSpace();
      space.replaceColliders([
        PhysicsWorldCollider.fromEntity(
          id: 'floor',
          entityX: 1,
          entityY: 0,
          entityZ: 1,
          shapeName: spec.shape,
          halfExtents: spec.halfExtents,
          offset: spec.offset,
        ),
      ]);
      final blocked = space.stepEyePosition(
        previousEye: vm.Vector3(1.0, 1.6, 3.6),
        desiredEye: vm.Vector3(1.0, 1.6, 3.1),
        dt: 1 / 60,
        applyGravity: false,
      );
      // Box center is z=1, hz=2 => maxZ=3.0 + defaultBodyRadius(0.25) = 3.25!
      expect(blocked.eyePosition.z, closeTo(3.25, 1e-2));
    },
  );

  test(
    'VrlwSceneAdapter.selectWithinBudget culls distant entities softly above 128 cap',
    () {
      final entities = List<VrWorldEntity>.generate(
        180,
        (i) => VrWorldEntity(
          id: 'prop_${i.toString().padLeft(3, '0')}',
          prototypeId: 'test.prop',
          world: VrWorldAddress(worldId: 'test.world', instanceId: 'local'),
          transform: VrWorldTransform(
            position: VrWorldPosition(i.toDouble(), 0, 0),
          ),
        ),
      );
      final selected = VrlwSceneAdapter.selectWithinBudget(
        entities,
        const {
          'test.prop': [100],
        },
        const {'test.prop': 0},
        vm.Vector3(50, 1.6, 0),
      );
      expect(selected.length, VrlwSceneAdapter.maxVisibleEntities);
      // Closest entity to x=50 is prop_050!
      expect(selected.first.id, 'prop_050');

      // Duplicate IDs still fail deterministically even under soft budget.
      expect(
        () => VrlwSceneAdapter.selectWithinBudget(
          [entities.first, entities.first],
          const {
            'test.prop': [100],
          },
          const {'test.prop': 0},
          vm.Vector3.zero(),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'VrCreatorService submits budgeted worlds and retro packages with budget payload',
    () async {
      final now = DateTime.utc(2026, 11, 14);
      final requests = <Map<String, dynamic>>[];
      late VrCreatorPackage activePackage;
      final service = VrCreatorService(
        endpoint: Uri.parse('https://creators.example/v1'),
        uploadOrigins: const {'https://storage.example'},
        clock: () => now,
        identity: () => VrCreatorIdentity(
          uid: 'uid-creator',
          profileId: 'profile-creator',
          isCurrent: () => true,
          getIdToken: () async => 'token-123',
        ),
        client: MockClient((req) async {
          if (req.method == 'PUT') return http.Response('', 200);
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          requests.add(body);
          if (body['action'] == 'beginUpload') {
            return http.Response(
              jsonEncode({
                'schemaVersion': 1,
                'uploadId': 'upload_budgeted_00001',
                'ownerUid': 'uid-creator',
                'profileId': 'profile-creator',
                'sha256': activePackage.sha256,
                'sizeBytes': activePackage.bytes.length,
                'uploadUrl': 'https://storage.example/quarantine/item.vrlz',
                'expiresAt': now
                    .add(const Duration(minutes: 5))
                    .millisecondsSinceEpoch,
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'schemaVersion': 1,
              'uploadId': 'upload_budgeted_00001',
              'ownerUid': 'uid-creator',
              'profileId': 'profile-creator',
              'packageId': activePackage.package.id,
              'status': 'pendingReview',
            }),
            200,
          );
        }),
      );
      addTearDown(service.close);

      // 1. Worlds package
      activePackage = VrCreatorPackage.validate(fixtureWorlds());
      final worldReceipt = await service.submit(activePackage);
      expect(worldReceipt.status, 'pendingReview');
      expect(requests.first['kind'], 'worlds');
      expect(requests.first['budget'], isA<Map<String, dynamic>>());
      expect((requests.first['budget'] as Map)['entryCount'], 2);

      // 2. Retro package
      requests.clear();
      final retroBytes = VrlzPackage.encodeRetro(
        level: VrlzRetroLevel.fromJson(retroLevelJson()),
        id: 'creator.retro_dungeon',
        title: 'Retro Dungeon',
        license: retroFixtureLicense,
      );
      activePackage = VrCreatorPackage.validate(retroBytes);
      final retroReceipt = await service.submit(activePackage);
      expect(retroReceipt.status, 'pendingReview');
      expect(requests.first['kind'], 'retro');
      expect(
        (requests.first['budget'] as Map)['archiveBytes'],
        retroBytes.length,
      );

      // 3. Builtin demo pointer remains blocked!
      final builtin = VrCreatorPackage.validate(fixtureBuiltin());
      await expectLater(service.submit(builtin), throwsStateError);
    },
  );
}
