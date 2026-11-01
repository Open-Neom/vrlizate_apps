import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;
import 'package:vrlizate_apps/src/viewer/vrlw_static_part_pool.dart';

String _fingerprint({
  int vertexCount = 3,
  int primitiveType = 0,
  bool sourceWindingFlipped = false,
  Float32List? positions,
  Float32List? normals,
  Float32List? texCoords,
  Float32List? texCoords1,
  Float32List? colors,
  Float32List? tangents,
  List<int>? indices,
  Map<String, ({int components, Float32List data})> customAttributes = const {},
}) => vrlwGeometryFingerprint(
  vertexCount: vertexCount,
  primitiveType: primitiveType,
  sourceWindingFlipped: sourceWindingFlipped,
  positions: positions ?? Float32List.fromList([0, 0, 0, 1, 0, 0, 0, 1, 0]),
  normals: normals,
  texCoords: texCoords,
  texCoords1: texCoords1,
  colors: colors,
  tangents: tangents,
  indices: indices,
  customAttributes: customAttributes,
);

// Equality is deliberately broader than identity, as can happen with material
// wrappers. Sharing must still require the exact renderer material instance.
class _Material {
  @override
  bool operator ==(Object other) => other is _Material;
  @override
  int get hashCode => 1;
}

void main() {
  test(
    'every rendered attribute, topology and source winding affects hash',
    () {
      final base = _fingerprint();
      final changed = [
        _fingerprint(vertexCount: 4),
        _fingerprint(primitiveType: 1),
        _fingerprint(sourceWindingFlipped: true),
        _fingerprint(
          positions: Float32List.fromList([1, 0, 0, 1, 0, 0, 0, 1, 0]),
        ),
        _fingerprint(normals: Float32List(9)),
        _fingerprint(texCoords: Float32List(6)),
        _fingerprint(texCoords1: Float32List(6)),
        _fingerprint(colors: Float32List(12)),
        _fingerprint(tangents: Float32List(12)),
        _fingerprint(indices: [0, 1, 2]),
        _fingerprint(indices: []),
        _fingerprint(
          customAttributes: {'a': (components: 1, data: Float32List(3))},
        ),
      ];
      expect(changed, everyElement(isNot(base)));
      expect(changed.toSet().length, changed.length);
      expect(_fingerprint(normals: Float32List(0)), isNot(base));
      expect(
        _fingerprint(indices: [0, 1, 2]),
        isNot(_fingerprint(indices: [0, 2, 1])),
      );
    },
  );

  test(
    'hash reads typed views at their real offset and normalizes index width',
    () {
      final positions = Float32List.fromList([0, 0, 0, 1, 0, 0, 0, 1, 0]);
      final padded = Float32List(positions.length + 4)..setAll(2, positions);
      final view = Float32List.sublistView(padded, 2, 2 + positions.length);
      expect(
        _fingerprint(
          positions: positions,
          indices: Uint16List.fromList([0, 1, 2]),
        ),
        _fingerprint(positions: view, indices: Uint32List.fromList([0, 1, 2])),
      );
      // More than one index hash chunk catches partial/tail handling.
      final indices = List.generate(515, (i) => i % 3);
      final before = _fingerprint(indices: indices);
      indices[514] = 2;
      expect(_fingerprint(indices: indices), isNot(before));
    },
  );

  test('custom attribute names, components and values all participate', () {
    final a = (components: 1, data: Float32List.fromList([1, 2, 3]));
    final b = (components: 1, data: Float32List.fromList([4, 5, 6]));
    final base = _fingerprint(customAttributes: {'a': a, 'b': b});
    expect(_fingerprint(customAttributes: {'b': b, 'a': a}), base);
    expect(_fingerprint(customAttributes: {'x': a, 'b': b}), isNot(base));
    expect(
      _fingerprint(
        customAttributes: {'a': (components: 3, data: a.data), 'b': b},
      ),
      isNot(base),
    );
    expect(_fingerprint(customAttributes: {'a': b, 'b': b}), isNot(base));
  });

  test(
    'equal parts across levels share one batch without losing occurrences',
    () {
      final pool = VrlwStaticPartPool<Object>();
      final material = _Material(), shadow = Object();
      final matrix = vm.Matrix4.identity().storage;
      final fingerprint = _fingerprint();
      var created = 0;
      Object resolve(int level) => pool.resolve(
        level: level,
        geometryFingerprint: fingerprint,
        transform: matrix,
        material: material,
        shadowMode: shadow,
        create: () {
          created++;
          return Object();
        },
      );
      final nearA = resolve(0), nearB = resolve(0);
      expect(nearB, isNot(same(nearA)));
      expect(resolve(1), same(nearA));
      expect(resolve(1), same(nearB));
      expect(resolve(2), same(nearA));
      expect(created, 2);
    },
  );

  test(
    'material identity, shadow policy, exact transform and prototype isolate',
    () {
      final pool = VrlwStaticPartPool<Object>();
      final material = _Material(), shadow = Object();
      final identity = vm.Matrix4.identity().storage;
      final fingerprint = _fingerprint();
      Object resolve({
        Object? mat,
        Object? cast,
        TypedData? transform,
        String? geometry,
        VrlwStaticPartPool<Object>? target,
        int level = 1,
      }) => (target ?? pool).resolve(
        level: level,
        geometryFingerprint: geometry ?? fingerprint,
        transform: transform ?? identity,
        material: mat ?? material,
        shadowMode: cast ?? shadow,
        create: Object.new,
      );
      final base = resolve(level: 0);
      expect(resolve(), same(base));
      expect(resolve(mat: _Material()), isNot(same(base)));
      expect(resolve(cast: Object()), isNot(same(base)));
      expect(
        resolve(geometry: _fingerprint(sourceWindingFlipped: true)),
        isNot(same(base)),
      );
      expect(
        resolve(transform: vm.Matrix4.translationValues(.001, 0, 0).storage),
        isNot(same(base)),
      );
      expect(
        resolve(transform: vm.Matrix4.diagonal3Values(-1, 1, 1).storage),
        isNot(same(base)),
      );
      final signedZero = Float32List.fromList(identity)..[12] = -0.0;
      expect(resolve(transform: signedZero), isNot(same(base)));
      expect(resolve(target: VrlwStaticPartPool<Object>()), isNot(same(base)));
    },
  );

  test(
    'pool stores signatures, so caller buffer mutation cannot rewrite a key',
    () {
      final pool = VrlwStaticPartPool<Object>();
      final material = Object(), shadow = Object();
      final matrix = vm.Matrix4.identity();
      final fingerprint = _fingerprint();
      final original = pool.resolve(
        level: 0,
        geometryFingerprint: fingerprint,
        transform: matrix.storage,
        material: material,
        shadowMode: shadow,
        create: Object.new,
      );
      matrix.setTranslationRaw(10, 20, 30);
      expect(
        pool.resolve(
          level: 1,
          geometryFingerprint: fingerprint,
          transform: vm.Matrix4.identity().storage,
          material: material,
          shadowMode: shadow,
          create: Object.new,
        ),
        same(original),
      );
    },
  );
}
