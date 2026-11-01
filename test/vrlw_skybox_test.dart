import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_apps/src/viewer/vrlw_skybox.dart';
import 'package:vrlizate_world/vrlizate_world.dart';

void main() {
  test(
    'a distinct KTX2 sky loads its own resource rather than the IBL',
    () async {
      final requested = <String>[];
      final sky = await loadVrlwAuthoredSky<String>(
        const VrlwEnvironmentSpec(
          environmentResource: 'room-lighting',
          skyboxResource: 'mountain-sky',
        ),
        resourceType: (_) => 'environment.ktx2',
        fromEnvironment: (id) async {
          requested.add(id);
          return 'visible:$id';
        },
        fromTexture: (_) async => throw StateError('Wrong decoder'),
      );
      expect(sky, 'visible:mountain-sky');
      expect(requested, ['mountain-sky']);
    },
  );

  for (final type in ['texture.png', 'texture.rgba8', 'texture.jpeg']) {
    test('$type sky works without an environment resource', () async {
      final sky = await loadVrlwAuthoredSky<String>(
        const VrlwEnvironmentSpec(skyboxResource: 'panorama'),
        resourceType: (_) => type,
        fromEnvironment: (_) async => throw StateError('Unexpected IBL bake'),
        fromTexture: (id) async => 'image:$id',
      );
      expect(sky, 'image:panorama');
    });
  }

  test('absent sky performs no loading even with an authored IBL', () async {
    final sky = await loadVrlwAuthoredSky<String>(
      const VrlwEnvironmentSpec(environmentResource: 'room-lighting'),
      resourceType: (_) => throw StateError('Unexpected resource lookup'),
      fromEnvironment: (_) async => throw StateError('Unexpected decode'),
      fromTexture: (_) async => throw StateError('Unexpected decode'),
    );
    expect(sky, isNull);
  });

  test(
    'a shared sky and IBL ID still resolves its independent visible sky',
    () async {
      final sky = await loadVrlwAuthoredSky<String>(
        const VrlwEnvironmentSpec(
          environmentResource: 'sky',
          skyboxResource: 'sky',
          environmentIntensity: 0,
        ),
        resourceType: (_) => 'environment.ktx2',
        fromEnvironment: (id) async => 'visible:$id',
        fromTexture: (_) async => throw StateError('Wrong decoder'),
      );
      expect(sky, 'visible:sky');
    },
  );

  test(
    'KTX2 texture sky fails before reaching the platform image decoder',
    () async {
      await expectLater(
        loadVrlwAuthoredSky<String>(
          const VrlwEnvironmentSpec(skyboxResource: 'panorama'),
          resourceType: (_) => 'texture.ktx2',
          fromEnvironment: (_) async => throw StateError('Wrong decoder'),
          fromTexture: (_) async => throw StateError('Platform codec called'),
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('cannot decode texture.ktx2'),
          ),
        ),
      );
    },
  );

  test('unsupported resources fail before either decoder is called', () async {
    await expectLater(
      loadVrlwAuthoredSky<String>(
        const VrlwEnvironmentSpec(skyboxResource: 'bad'),
        resourceType: (_) => 'model.glb',
        fromEnvironment: (_) async => throw StateError('Unexpected decode'),
        fromTexture: (_) async => throw StateError('Unexpected decode'),
      ),
      throwsFormatException,
    );
  });

  test(
    'panorama bindings keep sRGB, full intensity and sharp mip sampling',
    () {
      final source = VrlwSkyShader(
        cube: false,
        mip: true,
        hasBackground: true,
        backgroundIsLinear: false,
      );
      final bytes = source.getUniformBlock('SkyboxInfo')!;
      expect(Float32List.sublistView(bytes), [0, 1, 1, 0, 0, 0, 0, 0]);
      expect(
        Float32List.sublistView(source.getUniformBlock('RadianceLayoutInfo')!),
        [1, 0, 0, 0],
      );
      expect(source.useEnvironment, isFalse);
    },
  );

  test('KTX2 cube omits inactive layout binding and needs no image source', () {
    final source = VrlwSkyShader(
      cube: true,
      mip: false,
      hasBackground: false,
      backgroundIsLinear: false,
    );
    expect(source.getUniformBlock('RadianceLayoutInfo'), isNull);
    expect(Float32List.sublistView(source.getUniformBlock('SkyboxInfo')!), [
      0,
      1,
      0,
      0,
      0,
      0,
      0,
      0,
    ]);
    expect(source.useEnvironment, isFalse);
  });
}
