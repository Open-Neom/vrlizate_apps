import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vrlizate_apps/vrlizate_apps.dart';
import 'package:vrlizate_apps/vrlizate_apps_io.dart';
import '../tool/index_vrlz.dart' show writeVrlzIndex;
import 'support/retro_fixture.dart';
import 'support/nes_fixture.dart';
import 'support/vrz_fixture.dart';

void main() {
  test('retro package preserves data, license, source and immutable rows', () {
    final input = retroLevelJson();
    final level = VrlzRetroLevel.fromJson(input);
    final bytes = VrlzPackage.encodeRetro(
      level: level,
      id: 'org.example.retro',
      title: 'Retro original',
      description: 'A fixture',
      license: retroFixtureLicense,
    );
    final source = Uri.parse('https://example.org/games/test.vrlz');
    final package = VrlzPackage.decode(bytes, source: source);
    final bundle = package.retroBundle!;
    expect(package.kind, VrlzPackageKind.retro);
    expect(package.id, 'org.example.retro');
    expect(package.title, 'Retro original');
    expect(package.description, 'A fixture');
    expect(package.demoId, isNull);
    expect(package.nesBundle, isNull);
    expect(package.sceneBundle, isNull);
    expect(package.builtinManifest, isNull);
    expect(package.source, source);
    expect(bundle.source, source);
    expect(bundle.manifest.formatVersion, 4);
    expect(bundle.manifest.runtime, 'vrlizate.retro2d.v1');
    expect(bundle.manifest.entrypoint, 'level.json');
    expect(bundle.manifest.license, retroFixtureLicense);
    expect(bundle.level.toJson(), input);
    expect(bundle.level.width, 16);
    expect(bundle.level.height, 8);
    expect(package.encode(), bytes);
    final entries = ZipDecoder().decodeBytes(bytes);
    expect(entries.map((entry) => entry.name), ['manifest.json', 'level.json']);
    expect(
      entries.every((entry) => entry.compression == CompressionType.none),
      isTrue,
    );
    expect(
      bundle.manifest.levelSha256,
      sha256.convert(entries.findFile('level.json')!.content).toString(),
    );
    (input['rows']! as List)[0] = '################';
    expect(level.rows.first, '................');
    expect(() => level.rows[0] = '################', throwsUnsupportedError);
    expect(
      () => (level.toJson()['rows'] as List).clear(),
      throwsUnsupportedError,
    );
    expect(
      () => bundle.manifest.capabilities.add('network'),
      throwsUnsupportedError,
    );
    bytes.fillRange(0, bytes.length, 0);
    expect(
      VrlzPackage.decode(package.encode()).retroBundle!.level.toJson(),
      level.toJson(),
    );
  });

  final manifestMutations = <String, void Function(Map<String, dynamic>)>{
    'crossed format': (m) => m['formatVersion'] = 3,
    'floating format': (m) => m['formatVersion'] = 4.0,
    'wrong runtime': (m) => m['runtime'] = 'javascript',
    'unknown field': (m) => m['script'] = 'game.dart',
    'entrypoint path': (m) => m['entrypoint'] = '../level.json',
    'unqualified id': (m) => m['id'] = 'retro',
    'newline id': (m) => m['id'] = 'org.example.retro\n',
    'empty title': (m) => m['title'] = ' ',
    'long description': (m) => m['description'] = 'a' * 513,
    'extra capability': (m) => m['capabilities'] = ['game.retro2d', 'network'],
    'missing license': (m) => m.remove('license'),
    'short license': (m) => m['license'] = 'MIT',
    'long license': (m) => m['license'] = 'é' * 8193,
    'null license': (m) => m['license'] = '$retroFixtureLicense\u0000',
    'wrong hash': (m) => m['sha256'] = {'level.json': '0' * 64},
    'extra hash': (m) => (m['sha256'] as Map)['game.dart'] = '0' * 64,
  };
  for (final entry in manifestMutations.entries) {
    test('retro rejects ${entry.key}', () {
      expect(
        () => VrlzPackage.decode(fixtureRetro(changeManifest: entry.value)),
        throwsFormatException,
      );
    });
  }

  final levelMutations = <String, void Function(Map<String, Object?>)>{
    'script field': (m) => m['script'] = 'game.dart',
    'unknown theme': (m) => m['theme'] = 'mario',
    'unknown mode': (m) => m['mode'] = 'code',
    'empty name': (m) => m['name'] = '',
    'short height': (m) => (m['rows'] as List).removeAt(0),
    'large height': (m) => m['rows'] = List.filled(25, '.' * 16),
    'large width': (m) => m['rows'] = List.filled(8, '.' * 129),
    'non rectangular': (m) => (m['rows'] as List)[0] = '.',
    'non string row': (m) => (m['rows'] as List)[0] = 12,
    'unknown tile': (m) => (m['rows'] as List)[0] = 'z' * 16,
    'newline tile': (m) => (m['rows'] as List)[0] = '${'.' * 15}\n',
    'missing spawn': (m) => (m['rows'] as List)[6] = '.............G..',
    'duplicate spawn': (m) => (m['rows'] as List)[6] = '.SS..........G..',
    'missing exit': (m) => (m['rows'] as List)[6] = '..S.............',
    'unsupported spawn': (m) => (m['rows'] as List)[7] = '................',
    'blocked headroom': (m) => (m['rows'] as List)[5] = '################',
    'spawn boundary': (m) => (m['rows'] as List)[6] = 'S............G..',
    'too many enemies': (m) {
      final r = m['rows'] as List;
      r[0] = 'E' * 16;
      r[1] = 'E' * 16;
      r[2] = 'E...............';
    },
    'duplicate boss': (m) => (m['rows'] as List)[0] = 'BB..............',
    'too many checkpoints': (m) => (m['rows'] as List)[0] = 'KKKKKKKKK.......',
  };
  for (final entry in levelMutations.entries) {
    test('retro rejects level ${entry.key}', () {
      final json =
          jsonDecode(jsonEncode(retroLevelJson())) as Map<String, dynamic>;
      entry.value(json);
      expect(
        () => VrlzPackage.decode(fixtureRetro(level: json)),
        throwsFormatException,
      );
    });
  }

  test('runtime cannot be substituted and archive is exact and bounded', () {
    for (final bytes in [
      fixtureBundle(),
      fixtureBuiltin(),
      fixtureNes(),
      fixtureRetro(payloadName: '../level.json'),
      fixtureRetro(method: 8),
      fixtureRetro(
        extraEntries: [
          ZipFixtureEntry('code.dart', [1, 2, 3]),
        ],
      ),
      Uint8List(VrlzRetroBundle.maxBytes + 1),
    ]) {
      expect(() => VrlzRetroBundle.decode(bytes), throwsFormatException);
    }
    expect(() => VrzBundle.decode(fixtureRetro()), throwsFormatException);
    expect(() => VrlzNesBundle.decode(fixtureRetro()), throwsFormatException);
    final entries = ZipDecoder().decodeBytes(fixtureRetro());
    final payload = utf8.encode(
      jsonEncode({...retroLevelJson(), 'theme': 'neon'}),
    );
    expect(
      () => VrlzPackage.decode(
        storeZip([
          ZipFixtureEntry(
            'manifest.json',
            entries.findFile('manifest.json')!.content,
          ),
          ZipFixtureEntry('level.json', payload),
        ]),
      ),
      throwsFormatException,
    );
    final corrupted = fixtureRetro();
    corrupted[70] ^= 1;
    expect(() => VrlzPackage.decode(corrupted), throwsFormatException);
  });

  test(
    'retro discovers locally and downloads using existing HTTPS catalog',
    () async {
      final directory = await Directory.systemTemp.createTemp('vrlz-retro-');
      final bytes = fixtureRetro();
      final store = VrlzDirectoryStore(directory.path);
      final client = MockClient((_) async => http.Response.bytes(bytes, 200));
      final loader = VrlzWebCatalogLoader(client: client);
      try {
        final imported = await store.importBytes(bytes, filename: 'retro.vrlz');
        expect(imported.metadata.kind, VrlzPackageKind.retro);
        expect(imported.metadata.demoId, isNull);
        final snapshot = await store.scan();
        expect(snapshot.issues, isEmpty);
        final local = await store.load(snapshot.entries.single);
        expect(local.retroBundle!.level.toJson(), retroLevelJson());
        final index = await writeVrlzIndex(directory.path);
        final catalog = VrlzWebCatalog.decode(
          await index.readAsBytes(),
          source: Uri.parse('https://example.org/games/catalog.json'),
        );
        final downloaded = await loader.loadPackage(catalog.entries.single);
        expect(downloaded.kind, VrlzPackageKind.retro);
        expect(
          downloaded.retroBundle!.level.toJson(),
          local.retroBundle!.level.toJson(),
        );
      } finally {
        loader.close();
        client.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
