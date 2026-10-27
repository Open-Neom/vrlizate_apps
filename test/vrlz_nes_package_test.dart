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
import 'support/nes_fixture.dart';
import 'support/retro_fixture.dart';
import 'support/vrlz_world_fixture.dart';
import 'support/vrz_fixture.dart';
import 'support/web_game_fixture.dart';

void main() {
  test(
    'NES roundtrips its ROM and notices through an immutable exact container',
    () {
      final rom = nromFixture(prgBanks: 2, vertical: true);
      final original = Uint8List.fromList(rom);
      final bytes = VrlzPackage.encodeNes(
        romBytes: rom,
        id: 'org.example.nes',
        title: 'NROM',
        description: 'A portable cartridge.',
        license: nesFixtureLicense,
        sourceUrl: 'https://example.org/source',
      );
      final source = Uri.parse('https://example.org/download/game.vrlz');
      final package = VrlzPackage.decode(bytes, source: source);
      final bundle = package.nesBundle!;
      final manifest = bundle.manifest;
      expect(package.kind, VrlzPackageKind.nes);
      expect(package.id, 'org.example.nes');
      expect(package.title, 'NROM');
      expect(package.description, 'A portable cartridge.');
      expect(package.demoId, isNull);
      expect(package.sceneBundle, isNull);
      expect(package.builtinManifest, isNull);
      expect(package.source, source);
      expect(bundle.source, source);
      expect(manifest.formatVersion, 3);
      expect(manifest.runtime, 'vrlizate.nes.v1');
      expect(manifest.entrypoint, 'game.nes');
      expect(manifest.romSha256, sha256.convert(original).toString());
      expect(manifest.license, nesFixtureLicense);
      expect(manifest.sourceUrl, 'https://example.org/source');
      expect(bundle.romBytes, original);
      expect(package.encode(), bytes);
      final entries = ZipDecoder().decodeBytes(bytes);
      expect(entries.map((file) => file.name), ['manifest.json', 'game.nes']);
      expect(
        entries.every((file) => file.compression == CompressionType.none),
        isTrue,
      );
      rom.fillRange(0, rom.length, 7);
      bytes.fillRange(0, bytes.length, 9);
      bundle.romBytes.fillRange(0, original.length, 8);
      (manifest.toJson()['sha256'] as Map)['game.nes'] = '0' * 64;
      expect(bundle.romBytes, original);
      expect(manifest.romSha256, sha256.convert(original).toString());
      expect(
        () => manifest.capabilities.add('network'),
        throwsUnsupportedError,
      );
      expect(VrlzPackage.decode(package.encode()).source, isNull);
    },
  );

  test('all supported kinds dispatch exactly and scene reader rejects NES', () {
    final kinds = [
      fixtureBundle(),
      fixtureBuiltin(),
      fixtureNes(),
      fixtureRetro(),
      fixtureWorlds(),
      storeZip([
        ZipFixtureEntry('manifest.json', utf8.encode(jsonEncode(webGameJson()))),
      ]),
    ].map((bytes) => VrlzPackage.decode(bytes).kind).toSet();
    expect(kinds, VrlzPackageKind.values.toSet());
    expect(() => VrzBundle.decode(fixtureNes()), throwsFormatException);
    expect(() => VrlzNesBundle.decode(fixtureBundle()), throwsFormatException);
    expect(VrlzNesBundle.decode(fixtureNes()).romBytes, nromFixture());
    expect(
      VrlzPackage.decode(
        fixtureNes(changeManifest: (m) => m.remove('description')),
      ).description,
      '',
    );
  });

  final invalidManifest = <String, void Function(Map<String, dynamic>)>{
    'crossed format': (m) => m['formatVersion'] = 2,
    'floating format': (m) => m['formatVersion'] = 3.0,
    'unknown runtime': (m) => m['runtime'] = 'libretro.core.zip',
    'unknown field': (m) => m['nativeCore'] = 'core.so',
    'entrypoint path': (m) => m['entrypoint'] = '../game.nes',
    'unqualified id': (m) => m['id'] = 'nes',
    'id newline': (m) => m['id'] = 'org.example.nes\n',
    'blank title': (m) => m['title'] = ' ',
    'long description': (m) => m['description'] = 'a' * 513,
    'host capability': (m) => m['capabilities'] = ['host.builtin'],
    'extra capability': (m) => m['capabilities'] = ['emulator.nes', 'network'],
    'missing license': (m) => m.remove('license'),
    'license identifier only': (m) => m['license'] = 'Zlib',
    'oversize license bytes': (m) => m['license'] = 'é' * 8193,
    'license null byte': (m) => m['license'] = '$nesFixtureLicense\u0000',
    'missing source': (m) => m.remove('sourceUrl'),
    'HTTP source': (m) => m['sourceUrl'] = 'http://example.org/source',
    'relative source': (m) => m['sourceUrl'] = 'source',
    'credential source': (m) =>
        m['sourceUrl'] = 'https://u:p@example.org/source',
    'fragment source': (m) => m['sourceUrl'] = 'https://example.org/#source',
    'whitespace source': (m) => m['sourceUrl'] = ' https://example.org/source',
    'missing hash': (m) => m.remove('sha256'),
    'extra hash': (m) => (m['sha256'] as Map)['core.so'] = '0' * 64,
    'wrong hash': (m) => m['sha256'] = {'game.nes': '0' * 64},
    'uppercase hash': (m) => m['sha256'] = {'game.nes': 'A' * 64},
  };
  for (final entry in invalidManifest.entries) {
    test('NES rejects ${entry.key}', () {
      expect(
        () => VrlzPackage.decode(fixtureNes(changeManifest: entry.value)),
        throwsFormatException,
      );
    });
  }

  final invalidRom = <String, Uint8List Function()>{
    'bad magic': () => nromFixture()..[0] = 0,
    'empty PRG': () => nromFixture()..[4] = 0,
    'alternate console VS-Unisystem': () => nromFixture()..[7] = 1,
    'alternate console PlayChoice-10': () => nromFixture()..[7] = 2,
    'truncated': () => Uint8List.sublistView(nromFixture(), 0, 32),
  };
  for (final entry in invalidRom.entries) {
    test('NES rejects ${entry.key} even with matching SHA-256 and CRC', () {
      expect(
        () => VrlzPackage.decode(fixtureNes(rom: entry.value())),
        throwsFormatException,
      );
    });
  }

  test(
    'NES supports multi-mapper cartridges (UNROM, MMC1, MMC3, CHR-RAM, Battery SRAM, Trainer)',
    () {
      // UNROM (Mapper 2): 128 KiB PRG (8 banks) + CHR-RAM (0 CHR banks), like Mega Man 1
      final unrom = Uint8List(16 + 8 * 16384)
        ..setRange(0, 8, [0x4e, 0x45, 0x53, 0x1a, 8, 0, 0x21, 0]);
      final unromPkg = VrlzPackage.fromRawNesRom(
        unrom,
        fileName: 'mega_man_unrom.nes',
      );
      expect(unromPkg.kind, VrlzPackageKind.nes);
      expect(unromPkg.nesBundle!.mapperNumber, 2);
      expect(unromPkg.nesBundle!.mapperName, 'UNROM (UxROM)');
      expect(unromPkg.nesBundle!.hasChrRam, isTrue);
      expect(unromPkg.nesBundle!.prgKiB, 128);

      // MMC1 (Mapper 1) + Battery SRAM: 256 KiB PRG + CHR-RAM + Battery
      final mmc1 = Uint8List(16 + 16 * 16384)
        ..setRange(0, 8, [0x4e, 0x45, 0x53, 0x1a, 16, 0, 0x12, 0]);
      final mmc1Pkg = VrlzPackage.fromRawNesRom(mmc1, fileName: 'mmc1_rpg.nes');
      expect(mmc1Pkg.nesBundle!.mapperNumber, 1);
      expect(mmc1Pkg.nesBundle!.mapperName, 'MMC1 (SxROM)');
      expect(mmc1Pkg.nesBundle!.hasBatteryRam, isTrue);

      // MMC3 (Mapper 4): 256 KiB PRG + 128 KiB CHR (16 banks), like Mega Man 3-6 / SMB3
      final mmc3 = Uint8List(16 + 16 * 16384 + 16 * 8192)
        ..setRange(0, 8, [0x4e, 0x45, 0x53, 0x1a, 16, 16, 0x40, 0]);
      final mmc3Pkg = VrlzPackage.decode(fixtureNes(rom: mmc3));
      expect(mmc3Pkg.nesBundle!.mapperNumber, 4);
      expect(mmc3Pkg.nesBundle!.mapperName, 'MMC3 (TxROM)');
      expect(mmc3Pkg.nesBundle!.chrKiB, 128);
    },
  );

  test(
    'NES rejects payload swaps, native libraries, saved state and malformed ZIP',
    () {
      final rom = nromFixture();
      final manifest = utf8.encode(jsonEncode(nesFixtureManifest(rom)));
      for (final bytes in [
        fixtureNes(payloadName: 'scene.glb'),
        fixtureNes(payloadName: '../game.nes'),
        fixtureNes(method: 8),
        fixtureNes(
          extraEntries: [
            ZipFixtureEntry('core.so', [1]),
          ],
        ),
        fixtureNes(
          extraEntries: [
            ZipFixtureEntry('save.state', [1]),
          ],
        ),
        fixtureNes(extraEntries: [ZipFixtureEntry('game.nes', rom)]),
        storeZip([ZipFixtureEntry('manifest.json', manifest)]),
        storeZip([
          ZipFixtureEntry('manifest.json', manifest),
          ZipFixtureEntry('game.nes', rom, attributes: 0xa1ff0000),
        ]),
        fixtureBuiltin(extraEntries: [ZipFixtureEntry('game.nes', rom)]),
        Uint8List.fromList([...fixtureNes(), 1]),
        Uint8List(VrlzNesBundle.maxBytes + 1),
      ]) {
        expect(() => VrlzPackage.decode(bytes), throwsFormatException);
      }
      final altered = Uint8List.fromList(rom)..[20] ^= 1;
      expect(
        () => VrlzPackage.decode(
          storeZip([
            ZipFixtureEntry('manifest.json', manifest),
            ZipFixtureEntry('game.nes', altered),
          ]),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'NES imports locally (.vrlz and raw .nes), indexes and downloads through the existing catalog',
    () async {
      final directory = await Directory.systemTemp.createTemp('vrlz-nes-');
      final bytes = fixtureNes();
      final unromRaw = Uint8List(16 + 8 * 16384)
        ..setRange(0, 8, [0x4e, 0x45, 0x53, 0x1a, 8, 0, 0x21, 0]);
      final store = VrlzDirectoryStore(directory.path);
      final client = MockClient((request) async {
        expect(
          request.url.toString(),
          'https://example.org/games/cartridge.vrlz',
        );
        return http.Response.bytes(bytes, 200);
      });
      final loader = VrlzWebCatalogLoader(client: client);
      try {
        final imported = await store.importBytes(
          bytes,
          filename: 'cartridge.vrlz',
        );
        expect(imported.metadata.kind, VrlzPackageKind.nes);
        expect(imported.metadata.demoId, isNull);

        final importedRaw = await store.importBytes(
          unromRaw,
          filename: 'mega_buster.nes',
        );
        expect(importedRaw.metadata.kind, VrlzPackageKind.nes);
        expect(importedRaw.fileName, 'mega_buster.nes');

        final snapshot = await store.scan();
        expect(snapshot.issues, isEmpty);
        expect(snapshot.entries, hasLength(2));
        final loadedRaw = await store.load(
          snapshot.entries.firstWhere((e) => e.fileName == 'mega_buster.nes'),
        );
        expect(loadedRaw.nesBundle!.mapperNumber, 2);
        expect(loadedRaw.nesBundle!.romBytes, unromRaw);

        // Remove raw .nes before writeVrlzIndex which only indexes .vrlz files
        await File('${directory.path}/mega_buster.nes').delete();

        final snapshotSingle = await store.scan();
        final local = await store.load(snapshotSingle.entries.single);
        expect(local.nesBundle!.romBytes, nromFixture());
        expect(
          VrlzPackage.decode(local.encode()).nesBundle!.manifest.license,
          nesFixtureLicense,
        );
        final indexFile = await writeVrlzIndex(directory.path);
        final catalog = VrlzWebCatalog.decode(
          await indexFile.readAsBytes(),
          source: Uri.parse('https://example.org/games/catalog.json'),
        );
        expect(catalog.entries.single.sha256, sha256.convert(bytes).toString());
        final downloaded = await loader.loadPackage(catalog.entries.single);
        expect(downloaded.kind, VrlzPackageKind.nes);
        expect(downloaded.nesBundle!.romBytes, local.nesBundle!.romBytes);
      } finally {
        loader.close();
        client.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
