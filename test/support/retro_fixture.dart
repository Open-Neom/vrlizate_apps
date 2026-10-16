import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:vrlizate_apps/vrlizate_apps.dart';
import 'vrz_fixture.dart';

const retroFixtureLicense =
    'Original synthetic test data. Permission is granted '
    'to use, copy, modify and distribute this fixture without restriction.';

Map<String, Object?> retroLevelJson() => {
  'name': 'A small original course',
  'theme': 'garden',
  'mode': 'platformer',
  'rows': [
    '................',
    '................',
    '................',
    '................',
    '................',
    '................',
    '..S..*..E.K..G..',
    '################',
  ],
};

Uint8List fixtureRetro({
  void Function(Map<String, dynamic>)? changeManifest,
  Map<String, Object?>? level,
  String payloadName = 'level.json',
  int method = 0,
  List<ZipFixtureEntry> extraEntries = const [],
}) {
  final payload = utf8.encode(jsonEncode(level ?? retroLevelJson()));
  final manifest = <String, dynamic>{
    'formatVersion': 4,
    'id': 'org.example.retro',
    'title': 'Retro original',
    'description': 'A fixture',
    'runtime': 'vrlizate.retro2d.v1',
    'entrypoint': 'level.json',
    'capabilities': ['game.retro2d'],
    'sha256': {'level.json': sha256.convert(payload).toString()},
    'license': retroFixtureLicense,
  };
  changeManifest?.call(manifest);
  return storeZip([
    ZipFixtureEntry('manifest.json', utf8.encode(jsonEncode(manifest))),
    ZipFixtureEntry(payloadName, payload, method: method),
    ...extraEntries,
  ]);
}

VrlzRetroLevel retroLevel() => VrlzRetroLevel.fromJson(retroLevelJson());
