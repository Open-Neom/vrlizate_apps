import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_apps/vrlizate_apps.dart';

import 'support/vrz_fixture.dart';

void main() {
  test('builtin descriptor roundtrips without retaining caller data', () {
    final bytes = VrlzPackage.encodeBuiltin(
      id: 'org.example.room',
      title: 'Cuarto integrado',
      description: 'Una demo del anfitrión.',
      demoId: 'flutter_scene_room',
    );
    final source = Uri.parse('https://example.org/room.vrlz');
    final package = VrlzPackage.decode(bytes, source: source);
    expect(package.kind, VrlzPackageKind.builtin);
    expect(package.id, 'org.example.room');
    expect(package.title, 'Cuarto integrado');
    expect(package.description, 'Una demo del anfitrión.');
    expect(package.demoId, 'flutter_scene_room');
    expect(package.sceneBundle, isNull);
    expect(package.source, source);
    final manifest = package.builtinManifest!;
    expect(manifest.formatVersion, 2);
    expect(manifest.runtime, 'vrlizate.builtin.v1');
    expect(manifest.entrypoint, package.demoId);
    expect(manifest.toJson()['sha256'], isEmpty);
    final rebuilt = package.encode();
    expect(rebuilt, bytes, reason: 'Canonical descriptors are deterministic.');
    bytes.fillRange(0, bytes.length, 0);
    final json = manifest.toJson()..['title'] = 'Changed externally';
    expect(json['title'], isNot(package.title));
    expect(package.encode(), rebuilt);
    expect(() => manifest.capabilities.add('network'), throwsUnsupportedError);
    expect(VrlzPackage.decode(rebuilt).source, isNull);
  });

  test(
    'legacy scene bytes retain camera, checksum and payload through reencode',
    () {
      final scene = triangleGlb();
      final bytes = VrzBundle.encode(
        sceneBytes: scene,
        id: 'org.example.scene',
        title: 'Portable scene',
        description: 'Metadata survives local import.',
        cameraPosition: [2, 3, 4],
        cameraTarget: [-1, 0, -2],
      );
      final package = VrlzPackage.decode(bytes);
      expect(package.kind, VrlzPackageKind.scene);
      expect(package.demoId, isNull);
      expect(package.builtinManifest, isNull);
      expect(package.sceneBundle!.sceneBytes, scene);
      final decoded = VrzBundle.decode(package.encode());
      expect(decoded.manifest.toJson(), package.sceneBundle!.manifest.toJson());
      expect(decoded.manifest.cameraPosition, [2, 3, 4]);
      expect(decoded.manifest.cameraTarget, [-1, 0, -2]);
      expect(decoded.sceneBytes, scene);
    },
  );

  test('both kinds accept independently authored STORE archives', () {
    expect(VrlzPackage.decode(fixtureBuiltin()).kind, VrlzPackageKind.builtin);
    expect(VrlzPackage.decode(fixtureBundle()).kind, VrlzPackageKind.scene);
    expect(() => VrzBundle.decode(fixtureBuiltin()), throwsFormatException);
  });

  final invalid = <String, void Function(Map<String, dynamic>)>{
    'scene format version': (m) => m['formatVersion'] = 1,
    'future format version': (m) => m['formatVersion'] = 3,
    'floating format version': (m) => m['formatVersion'] = 2.0,
    'scene runtime': (m) => m['runtime'] = 'vrlizate.scene.v1',
    'script runtime': (m) => m['runtime'] = 'dart',
    'missing runtime': (m) => m.remove('runtime'),
    'script field': (m) => m['script'] = 'main.dart',
    'scene camera': (m) => m['camera'] = {
      'position': [0, 1, 2],
      'target': [0, 1, 0],
    },
    'missing hash object': (m) => m.remove('sha256'),
    'array hash object': (m) => m['sha256'] = [],
    'nonempty hash object': (m) => m['sha256'] = {'scene.glb': '0' * 64},
    'scene capability': (m) => m['capabilities'] = ['scene.gltf2'],
    'extra capability': (m) => m['capabilities'] = ['host.builtin', 'network'],
    'duplicate capability': (m) =>
        m['capabilities'] = ['host.builtin', 'host.builtin'],
    'unqualified package id': (m) => m['id'] = 'room',
    'id trailing newline': (m) => m['id'] = 'org.example.room\n',
    'blank title': (m) => m['title'] = '  ',
    'long title': (m) => m['title'] = 'a' * 81,
    'long description': (m) => m['description'] = 'a' * 513,
    'nonstring description': (m) => m['description'] = [],
    'empty demo': (m) => m['entrypoint'] = '',
    'nonstring demo': (m) => m['entrypoint'] = 4,
    'uppercase demo': (m) => m['entrypoint'] = 'Room',
    'demo path': (m) => m['entrypoint'] = '../flutter_scene_room',
    'demo file': (m) => m['entrypoint'] = 'main.dart',
    'demo URL': (m) => m['entrypoint'] = 'https://example.org/demo',
    'demo trailing newline': (m) => m['entrypoint'] = 'room\n',
    'long demo': (m) => m['entrypoint'] = 'a' * 129,
  };
  for (final entry in invalid.entries) {
    test('rejects builtin ${entry.key}', () {
      expect(
        () => VrlzPackage.decode(fixtureBuiltin(changeManifest: entry.value)),
        throwsFormatException,
      );
    });
  }

  test('a missing optional description has a stable empty value', () {
    final package = VrlzPackage.decode(
      fixtureBuiltin(changeManifest: (m) => m.remove('description')),
    );
    expect(package.description, '');
    expect(VrlzPackage.decode(package.encode()).description, '');
  });

  test('schema validation does not invent host support for a demo', () {
    // Unknown-but-well-formed identifiers are data. The host's explicit registry
    // decides availability; this parser must never import code to resolve them.
    final package = VrlzPackage.decode(
      fixtureBuiltin(
        changeManifest: (m) => m['entrypoint'] = 'future_host_demo',
      ),
    );
    expect(package.demoId, 'future_host_demo');
    expect(package.sceneBundle, isNull);
  });

  test(
    'builtin rejects scene payloads, duplicate manifests and executable files',
    () {
      for (final entry in [
        ZipFixtureEntry('scene.glb', triangleGlb()),
        ZipFixtureEntry('manifest.json', []),
        ZipFixtureEntry('main.dart', utf8.encode('void main() {}')),
        ZipFixtureEntry('../manifest.json', []),
      ]) {
        expect(
          () => VrlzPackage.decode(fixtureBuiltin(extraEntries: [entry])),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'a corrupt or incomplete scene is never retried as a builtin descriptor',
    () {
      for (final bytes in [
        fixtureBundle(
          changeManifest: (m) => m['sha256'] = {'scene.glb': '0' * 64},
        ),
        fixtureBundle(scene: triangleGlb()..[0] = 0),
        fixtureBundle(
          changeManifest: (m) => m['runtime'] = 'vrlizate.builtin.v1',
        ),
        storeZip([
          ZipFixtureEntry(
            'manifest.json',
            utf8.encode(jsonEncode(vrzManifest(triangleGlb()))),
          ),
        ]),
      ]) {
        expect(() => VrlzPackage.decode(bytes), throwsFormatException);
      }
    },
  );

  test('one-entry archives retain strict ZIP flags, CRC and size limits', () {
    final manifest = utf8.encode(jsonEncode(vrlzBuiltinManifest()));
    final corrupt = fixtureBuiltin()..[30 + 'manifest.json'.length + 2] ^= 1;
    final badHeader = fixtureBuiltin()..[14] ^= 1;
    for (final bytes in [
      corrupt,
      badHeader,
      storeZip([ZipFixtureEntry('manifest.json', manifest, method: 8)]),
      storeZip([ZipFixtureEntry('manifest.json', manifest, flags: 1)]),
      storeZip([ZipFixtureEntry('manifest.json', manifest, flags: 8)]),
      storeZip([
        ZipFixtureEntry('manifest.json', manifest, attributes: 0xa1ff0000),
      ]),
      storeZip([ZipFixtureEntry('manifest.json', manifest, attributes: 0x10)]),
      storeZip([ZipFixtureEntry('manifest.json', List.filled(65537, 32))]),
      storeZip([ZipFixtureEntry('scene.glb', triangleGlb())]),
      Uint8List(VrlzPackage.maxBytes + 1),
      Uint8List.fromList([...fixtureBuiltin(), 0]),
      Uint8List(0),
    ]) {
      expect(() => VrlzPackage.decode(bytes), throwsFormatException);
    }
  });
}
