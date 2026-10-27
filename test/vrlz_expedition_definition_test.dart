import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_apps/vrlizate_apps.dart';

import 'support/vrlz_expedition_fixture.dart';

void main() {
  test('definition JSON and bytes round trip through a closed data schema', () {
    final definition = expeditionFixture();
    final json = definition.toJson();
    expect(json['schemaVersion'], 1);
    expect(VrlzExpeditionDefinition.fromJson(json).toJson(), json);
    expect(
      VrlzExpeditionDefinition.fromBytes(
        Uint8List.fromList(utf8.encode(jsonEncode(json))),
      ).toJson(),
      json,
    );
    json['worlds']['garden'] = 'Changed';
    json['missions'][0]['position'][0] = 99.0;
    expect(definition.worlds['garden'], 'Jardín');
    expect(definition.missions.first.position[0], 1);
  });

  test('all authored collections are defensively copied and immutable', () {
    final coords = <double>[1, 2, 3];
    final mission = VrlzExpeditionMission(
      id: 'm',
      world: 'garden',
      title: 'T',
      instruction: 'I',
      discovery: 'D',
      position: coords,
    );
    final worlds = {'garden': 'Jardín'}, missions = [mission];
    final definition = VrlzExpeditionDefinition(
      id: 'quest',
      experienceId: 'worlds',
      title: 'T',
      revision: 1,
      worlds: worlds,
      missions: missions,
    );
    coords[0] = 99;
    worlds.clear();
    missions.clear();
    expect(mission.position, [1, 2, 3]);
    expect(definition.worlds, {'garden': 'Jardín'});
    expect(definition.missions, hasLength(1));
    expect(() => mission.position.clear(), throwsUnsupportedError);
    expect(() => definition.worlds.clear(), throwsUnsupportedError);
    expect(() => definition.missions.clear(), throwsUnsupportedError);
  });

  test(
    'constructor bounds IDs, coordinates, radius, sequence and references',
    () {
      VrlzExpeditionMission m({
        String id = 'm',
        String world = 'garden',
        List<double>? position,
        double radius = 2.5,
      }) => VrlzExpeditionMission(
        id: id,
        world: world,
        title: 'T',
        instruction: 'I',
        discovery: 'D',
        position: position ?? [1, 2, 3],
        radius: radius,
      );
      for (final bad in <List<double>>[
        [1, 2],
        [1, 2, double.nan],
        [1, 2, double.infinity],
        [1e7, 2, 3],
      ]) {
        expect(() => m(position: bad), throwsArgumentError);
      }
      for (final radius in [0.0, .09, 10.1, double.nan, double.infinity]) {
        expect(() => m(radius: radius), throwsArgumentError);
      }
      expect(() => m(id: '../m'), throwsArgumentError);
      VrlzExpeditionDefinition d(
        List<VrlzExpeditionMission> missions, {
        int revision = 1,
        Map<String, String>? worlds,
      }) => VrlzExpeditionDefinition(
        id: 'q',
        experienceId: 'w',
        title: 'T',
        revision: revision,
        worlds: worlds ?? {'garden': 'G'},
        missions: missions,
      );
      expect(() => d([m(), m()]), throwsArgumentError);
      expect(() => d([m(world: 'unknown')]), throwsArgumentError);
      expect(() => d([]), throwsArgumentError);
      expect(() => d([m()], revision: 0), throwsArgumentError);
      expect(
        () => d([m()], worlds: {for (var i = 0; i < 33; i++) 'w$i': 'W'}),
        throwsArgumentError,
      );
      expect(
        () => d([for (var i = 0; i < 129; i++) m(id: 'm$i')]),
        throwsArgumentError,
      );
    },
  );

  final invalid = <String, void Function(Map<String, dynamic>)>{
    'schema': (x) => x['schemaVersion'] = 2,
    'unknown field': (x) => x['script'] = 'eval',
    'missing title': (x) => x.remove('title'),
    'world type': (x) => x['worlds'] = {'garden': 12},
    'empty worlds': (x) => x['worlds'] = {},
    'mission type': (x) => x['missions'] = ['script'],
    'mission unknown field': (x) => x['missions'][0]['run'] = 'code',
    'mission missing field': (x) => x['missions'][0].remove('discovery'),
    'mission unknown world': (x) => x['missions'][0]['world'] = 'other',
    'mission numeric field': (x) => x['missions'][0]['title'] = 3,
    'mission invalid radius': (x) => x['missions'][0]['radius'] = 100,
    'mission invalid coordinate': (x) =>
        x['missions'][0]['position'] = [1000001, 0, 0],
  };
  for (final entry in invalid.entries) {
    test('definition parser rejects ${entry.key}', () {
      final json = expeditionFixture().toJson();
      entry.value(json);
      expect(
        () => VrlzExpeditionDefinition.fromJson(json),
        throwsFormatException,
      );
    });
  }
  test('definition bytes enforce size and strict UTF-8/JSON before use', () {
    for (final data in [
      Uint8List(0),
      Uint8List(VrlzExpeditionDefinition.maxBytes + 1),
      Uint8List.fromList([255]),
      Uint8List.fromList(utf8.encode('[]')),
    ]) {
      expect(
        () => VrlzExpeditionDefinition.fromBytes(data),
        throwsFormatException,
      );
    }
  });
}
