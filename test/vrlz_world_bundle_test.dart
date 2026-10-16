import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_apps/vrlizate_apps.dart';

import 'support/vrlz_world_fixture.dart';
import 'support/vrz_fixture.dart';

void main() {
  test(
    'portable package roundtrips and opens validated resource prototypes',
    () async {
      final bytes = fixtureWorlds();
      final package = VrlzPackage.decode(bytes);
      expect(package.kind, VrlzPackageKind.worlds);
      final bundle = package.worldBundle!;
      expect(bundle.manifest.worlds.length, 2);
      expect(bundle.manifest.portals.length, 2);
      expect(VrlzPackage.decode(package.encode()).id, package.id);
      bytes.fillRange(0, bytes.length, 0);
      final prepared = await bundle.openWorld('garden');
      expect(prepared.reader.registeredPrototypeIds, {'test.floor'});
      expect(prepared.resources['floor.model'], triangleGlb());
      expect(prepared.resources['floor.color'], [255, 255, 255, 255]);
      await prepared.reader.close();
      expect(prepared.reader.isClosed, isTrue);
    },
  );

  final invalid = <String, void Function(Map<String, dynamic>)>{
    'future format': (m) => m['formatVersion'] = 2,
    'float format': (m) => m['formatVersion'] = 1.0,
    'unknown runtime': (m) => m['runtime'] = 'dart',
    'network capability': (m) =>
        m['capabilities'] = ['worlds.local', 'network'],
    'missing title': (m) => m.remove('title'),
    'extra code entry': (m) => m['code'] = 'main.dart',
    'unsafe experience id': (m) => m['id'] = '../../outside',
    'unknown entrypoint': (m) => m['entrypoint'] = 'missing',
    'unsafe world file': (m) => m['worlds'][0]['file'] = '../world.vrlw',
    'duplicate world id': (m) => m['worlds'][1]['id'] = m['worlds'][0]['id'],
    'bad file hash': (m) => m['worlds'][0]['sha256'] = '0' * 64,
    'bad index hash': (m) => m['worlds'][0]['indexSha256'] = '0' * 64,
    'outside spawn': (m) => m['worlds'][0]['spawn'] = [200, 1.6, 200],
    'unknown portal target': (m) => m['portals'][0]['to'] = 'missing',
    'self portal': (m) => m['portals'][0]['to'] = 'garden',
    'duplicate portal': (m) => m['portals'][1]['id'] = 'to_gallery',
    'outside portal': (m) => m['portals'][0]['position'] = [-1, 1.6, -1],
    'outside arrival': (m) => m['portals'][0]['arrival'] = [100, 1.6, 100],
    'unreachable world': (m) => m['portals'] = [],
    'oversized label': (m) => m['portals'][0]['label'] = 'x' * 97,
    'large yaw': (m) => m['worlds'][0]['yaw'] = 50,
  };
  for (final entry in invalid.entries) {
    test('rejects ${entry.key}', () {
      final fixture = worldFixture();
      entry.value(fixture.manifest);
      expect(
        () => VrlzWorldBundle.decode(
          uncheckedWorldArchive(fixture.manifest, fixture.files),
        ),
        throwsFormatException,
      );
    });
  }

  test('rejects undeclared safe-named ZIP payloads', () {
    final fixture = worldFixture();
    fixture.files['world_hidden.vrlw'] = Uint8List.fromList([1, 2, 3]);
    expect(
      () => VrlzPackage.decode(
        uncheckedWorldArchive(fixture.manifest, fixture.files),
      ),
      throwsFormatException,
    );
  });

  test('invalid GLB never becomes a prepared/renderable world', () async {
    final fixture = worldFixture(
      model: triangleGlb(
        changeJson: (json) {
          json['animations'] = [{}];
        },
      ),
    );
    final bundle = VrlzWorldBundle.decode(
      VrlzWorldBundle.encode(fixture.manifest, fixture.files),
    );
    await expectLater(bundle.openWorld('garden'), throwsFormatException);
  });

  test('GLB external resources are rejected before registration', () async {
    final model = triangleGlb(
      changeJson: (j) {
        j['buffers'][0]['uri'] = 'https://example.org/model.bin';
      },
    );
    final fixture = worldFixture(model: model);
    final bundle = VrlzWorldBundle.decode(
      VrlzWorldBundle.encode(fixture.manifest, fixture.files),
    );
    await expectLater(bundle.openWorld('gallery'), throwsFormatException);
  });

  test(
    'instanced GLB node triangle sum must stay below 20k per model',
    () async {
      final model = triangleGlb(
        changeJson: (json) {
          final primitive = Map<String, dynamic>.from(
            json['meshes'][0]['primitives'][0],
          );
          json['meshes'][0]['primitives'] = List.generate(
            11,
            (_) => Map.of(primitive),
          );
          json['nodes'] = List.generate(2048, (_) => {'mesh': 0});
          json['scenes'][0]['nodes'] = List.generate(2048, (i) => i);
        },
      );
      final fixture = worldFixture(model: model);
      final bundle = VrlzWorldBundle.decode(
        VrlzWorldBundle.encode(fixture.manifest, fixture.files),
      );
      await expectLater(bundle.openWorld('garden'), throwsFormatException);
    },
  );

  test('profile rejects world cell sizes beyond the host budget', () {
    final fixture = worldFixture(
      changeWorld: (world) => world['cellSizeMeters'] = 256,
    );
    expect(
      () => VrlzWorldBundle.encode(fixture.manifest, fixture.files),
      throwsFormatException,
    );
  });
}
