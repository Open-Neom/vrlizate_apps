import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'vrz_fixture.dart';

// Synthetic zero-filled cartridge for format checks; not a distributed game.
Uint8List nromFixture({int prgBanks = 1, bool vertical = false}) {
  final bytes = Uint8List(16 + prgBanks * 16384 + 8192);
  bytes.setRange(0, 8, [
    0x4e,
    0x45,
    0x53,
    0x1a,
    prgBanks,
    1,
    vertical ? 1 : 0,
    0,
  ]);
  return bytes;
}

const nesFixtureLicense =
    'Synthetic fixture authored for this test. Permission '
    'is granted to use, copy, modify and distribute this fixture without restriction.';

Map<String, dynamic> nesFixtureManifest(Uint8List rom) => {
  'formatVersion': 3,
  'id': 'org.example.nes',
  'title': 'Synthetic NROM',
  'description': 'A cartridge format test, not a playable game.',
  'runtime': 'vrlizate.nes.v1',
  'entrypoint': 'game.nes',
  'capabilities': ['emulator.nes'],
  'sha256': {'game.nes': sha256.convert(rom).toString()},
  'license': nesFixtureLicense,
  'sourceUrl': 'https://example.org/fixture/source',
};

Uint8List fixtureNes({
  Uint8List? rom,
  void Function(Map<String, dynamic>)? changeManifest,
  String payloadName = 'game.nes',
  int method = 0,
  List<ZipFixtureEntry> extraEntries = const [],
}) {
  final cartridge = rom ?? nromFixture();
  final manifest = nesFixtureManifest(cartridge);
  changeManifest?.call(manifest);
  return storeZip([
    ZipFixtureEntry('manifest.json', utf8.encode(jsonEncode(manifest))),
    ZipFixtureEntry(payloadName, cartridge, method: method),
    ...extraEntries,
  ]);
}
