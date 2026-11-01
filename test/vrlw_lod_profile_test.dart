import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_apps/vrlizate_apps.dart';

import 'support/vrlw_lod_fixture.dart';
import 'support/vrlz_world_fixture.dart';

VrlzWorldBundle bundle({
  Uint8List? model,
  void Function(Map<String, dynamic>)? changeWorld,
}) {
  final fixture = worldFixture(
    model: model ?? lodGlb(),
    changeWorld: (source) {
      addLodBinding(source);
      changeWorld?.call(source);
    },
  );
  return VrlzWorldBundle.decode(
    VrlzWorldBundle.encode(fixture.manifest, fixture.files),
  );
}

void main() {
  test(
    'prepares three strictly smaller roots inside one model before GPU',
    () async {
      final prepared = await bundle().openWorld('garden');
      addTearDown(prepared.reader.close);
      final binding = prepared.reader.index.prototypeBindings.single;
      expect(binding.lods.map((level) => level.node), ['lod0', 'lod1', 'lod2']);
      expect(
        prepared.resources.keys,
        containsAll(['floor.model', 'floor.color']),
      );
      expect(prepared.resources.length, 2);
      expect(prepared.reader.index.motions, isEmpty);
    },
  );

  final invalid = <String, void Function(Map<String, dynamic>)>{
    'missing root': (doc) => doc['nodes'][0]['name'] = 'different',
    'ambiguous root name': (doc) => doc['nodes'][3]['name'] = 'lod0',
    'root only in inactive scene': (doc) {
      doc['scenes'][0]['nodes'] = [0, 1];
      doc['scenes'].add({
        'nodes': [2],
      });
    },
    'additional scene geometry outside levels': (doc) {
      doc['nodes'].add({'mesh': 2});
      doc['scenes'][0]['nodes'].add(6);
    },
    'translated root': (doc) => doc['nodes'][0]['translation'] = [1, 0, 0],
    'scaled root': (doc) => doc['nodes'][0]['scale'] = [2, 2, 2],
    'explicit identity root': (doc) =>
        doc['nodes'][0]['translation'] = [0, 0, 0],
    'empty level': (doc) => doc['nodes'][2].remove('children'),
    'duplicate triangles instead of reduction': (doc) =>
        doc['nodes'][4]['mesh'] = 0,
    'increasing triangles far away': (doc) => doc['nodes'][5]['mesh'] = 0,
    'extra far primitives despite triangle reduction': (doc) {
      // LOD0 has four triangles in one primitive, LOD1 two in two primitives.
      doc['meshes'][1]['primitives'] = [
        {
          'attributes': {'POSITION': 2},
          'material': 0,
        },
        {
          'attributes': {'POSITION': 2},
          'material': 0,
        },
      ];
    },
    'overlapping subtrees': (doc) => doc['nodes'][1]['children'] = [3],
  };
  for (final entry in invalid.entries) {
    test('rejects ${entry.key} before GPU import', () async {
      await expectLater(
        bundle(model: lodGlb(changeJson: entry.value)).openWorld('garden'),
        throwsFormatException,
      );
    });
  }

  test(
    'legacy binding cannot render all variants of a shared LOD model',
    () async {
      final package = bundle(
        changeWorld: (source) {
          source['prototypes'].add('test.other');
          source['prototypeBindings'].add({
            'prototypeId': 'test.other',
            'model': 'floor.model',
          });
        },
      );
      await expectLater(package.openWorld('garden'), throwsFormatException);
    },
  );

  test(
    'equivalent LOD roots may be shared by separate static prototypes',
    () async {
      final package = bundle(
        changeWorld: (source) {
          source['prototypes'].add('test.other');
          source['prototypeBindings'].add(<String, dynamic>{
            ...source['prototypeBindings'][0] as Map,
            'prototypeId': 'test.other',
          });
        },
      );
      final prepared = await package.openWorld('garden');
      addTearDown(prepared.reader.close);
      expect(prepared.reader.index.prototypeBindings.length, 2);
      expect(prepared.resources.length, 2);
    },
  );

  test(
    'LOD levels together still obey the existing total model budget',
    () async {
      final model = lodGlb(
        changeJson: (doc) {
          // Each level fits (12,000/6,000/3,000 triangles), but their retained
          // total exceeds 20,000. All other GLB budgets remain valid.
          for (var level = 0; level < 3; level++) {
            doc['meshes'][level]['primitives'] = [
              for (var i = 0; i < 100; i++)
                {
                  'attributes': {'POSITION': level},
                  'material': 0,
                },
            ];
            for (var i = 0; i < 29; i++) {
              doc['nodes'][level]['children'].add(doc['nodes'].length);
              doc['nodes'].add({'mesh': level});
            }
          }
        },
      );
      await expectLater(
        bundle(model: model).openWorld('garden'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('submitted geometry budget exceeded'),
          ),
        ),
      );
    },
  );
}
