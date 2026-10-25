import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_apps/vrlizate_apps.dart';

import 'support/vrlz_world_fixture.dart';

void main() {
  late VrlzWorldBundle bundle;
  setUp(() => bundle = VrlzWorldBundle.decode(fixtureWorlds()));

  test(
    'only declared nearby portals travel and cycles restore visited poses',
    () {
      final session = VrlzWorldSession(bundle);
      expect(session.currentWorld, 'garden');
      expect(session.enterPortal('invented'), isFalse);
      expect(session.enterPortal('to_garden'), isFalse);
      session.updatePose(const VrlzWorldPose(x: 11, y: 1.6, z: 11, yaw: .7));
      expect(session.enterPortal('to_gallery'), isFalse);
      session.updatePose(const VrlzWorldPose(x: 2, y: 1.6, z: 3, yaw: .7));
      expect(session.enterPortal('to_gallery'), isTrue);
      expect(session.currentWorld, 'gallery');
      expect(session.pose.position, [4, 1.6, 4]);
      expect(session.pose.yaw, 1);
      expect(session.enterPortal('to_garden'), isTrue);
      expect(session.pose.position, [2, 1.6, 3]);
      expect(session.pose.yaw, .7);
    },
  );

  test('fresh session restores current world and all visit poses', () {
    final original = VrlzWorldSession(bundle);
    original.updatePose(const VrlzWorldPose(x: 3, y: 1.7, z: 3, yaw: .6));
    original.enterPortal('to_gallery');
    original.updatePose(const VrlzWorldPose(x: 6, y: 1.6, z: 4, yaw: 1.2));
    final fresh = VrlzWorldSession(bundle);
    expect(fresh.restoreSnapshot(original.encodeSnapshot()), isTrue);
    expect(fresh.currentWorld, 'gallery');
    expect(fresh.pose.position, [6, 1.6, 4]);
    expect(fresh.pose.yaw, 1.2);
    expect(fresh.enterPortal('to_garden'), isTrue);
    expect(fresh.pose.position, [3, 1.7, 3]);
    expect(fresh.pose.yaw, .6);
  });

  test('host selection uses authored spawns and keeps each visited pose', () {
    final session = VrlzWorldSession(bundle);
    session.updatePose(const VrlzWorldPose(x: 3, y: 1.6, z: 4, yaw: .6));
    expect(session.selectWorld('gallery'), isTrue);
    expect(session.currentWorld, 'gallery');
    // The authored spawn differs from the portal's arrival [4, 1.6, 4].
    expect(session.pose.position, [2, 1.6, 2]);
    expect(session.pose.yaw, 0);
    session.updatePose(const VrlzWorldPose(x: 7, y: 1.6, z: 6, yaw: .9));
    expect(session.selectWorld('garden'), isTrue);
    expect(session.pose.position, [3, 1.6, 4]);
    expect(session.pose.yaw, .6);
    expect(session.selectWorld('gallery'), isTrue);
    expect(session.pose.position, [7, 1.6, 6]);
    expect(session.pose.yaw, .9);
    expect(session.visits.keys, unorderedEquals(['garden', 'gallery']));
  });

  test('explicit selection after restore keeps both saved world poses', () {
    final original = VrlzWorldSession(bundle);
    original.updatePose(const VrlzWorldPose(x: 3, y: 1.7, z: 3, yaw: .6));
    original.selectWorld('gallery');
    original.updatePose(const VrlzWorldPose(x: 6, y: 1.6, z: 4, yaw: 1.2));
    final fresh = VrlzWorldSession(bundle);
    expect(fresh.restoreSnapshot(original.encodeSnapshot()), isTrue);
    expect(fresh.currentWorld, 'gallery');
    expect(fresh.selectWorld('garden'), isTrue);
    expect(fresh.pose.position, [3, 1.7, 3]);
    expect(fresh.pose.yaw, .6);
    final next = VrlzWorldSession(bundle);
    expect(next.restoreSnapshot(fresh.encodeSnapshot()), isTrue);
    expect(next.currentWorld, 'garden');
    expect(next.selectWorld('gallery'), isTrue);
    expect(next.pose.position, [6, 1.6, 4]);
    expect(next.pose.yaw, 1.2);
  });

  test(
    'unvisited explicit destination after restore uses its authored spawn',
    () {
      final original = VrlzWorldSession(bundle);
      original.updatePose(const VrlzWorldPose(x: 3, y: 1.6, z: 3, yaw: .6));
      final fresh = VrlzWorldSession(bundle);
      expect(fresh.restoreSnapshot(original.encodeSnapshot()), isTrue);
      expect(fresh.selectWorld('gallery'), isTrue);
      expect(fresh.pose.position, [2, 1.6, 2]);
      expect(fresh.selectWorld('garden'), isTrue);
      expect(fresh.pose.position, [3, 1.6, 3]);
    },
  );

  test(
    'invalid or unchanged host selections leave navigation state intact',
    () {
      final session = VrlzWorldSession(bundle);
      session.selectWorld('gallery');
      session.updatePose(const VrlzWorldPose(x: 6, y: 1.6, z: 4, yaw: 1.2));
      final before = VrlzWorldSnapshot.decode(session.encodeSnapshot());
      for (final alias in [
        '',
        '../gallery',
        'Gallery',
        'vrlz:test.experience',
      ]) {
        expect(session.selectWorld(alias), isFalse, reason: alias);
        expect(session.currentWorld, 'gallery');
        expect(session.pose.position, [6, 1.6, 4]);
      }
      expect(session.selectWorld('gallery'), isTrue);
      final after = VrlzWorldSnapshot.decode(session.encodeSnapshot());
      expect(after['currentWorld'], before['currentWorld']);
      expect(after['visits'], before['visits']);
      expect(after['sequence'], before['sequence']);
    },
  );

  test('three host destinations retain all six connected portal routes', () {
    const aliases = ['garden', 'gallery', 'alpine'];
    final fixture = worldFixture(worldAliases: aliases);
    fixture.manifest['portals'] = [
      for (final from in aliases)
        for (final to in aliases)
          if (from != to)
            {
              'id': '${from}_to_$to',
              'from': from,
              'to': to,
              'position': [2, 1.6, 2],
              'arrival': [4, 1.6, 4],
              'yaw': 1,
              'label': to,
            },
    ];
    final connected = VrlzWorldBundle.decode(
      VrlzWorldBundle.encode(fixture.manifest, fixture.files),
    );
    final session = VrlzWorldSession(connected);
    for (final portal in connected.manifest.portals) {
      expect(session.selectWorld(portal.from), isTrue);
      session.updatePose(const VrlzWorldPose(x: 2, y: 1.6, z: 2, yaw: .7));
      expect(session.enterPortal(portal.id), isTrue, reason: portal.id);
      expect(session.currentWorld, portal.to);
    }
    expect(connected.manifest.portals, hasLength(6));
    expect(session.visits.keys, unorderedEquals(aliases));
    final restored = VrlzWorldSession(connected);
    expect(restored.restoreSnapshot(session.encodeSnapshot()), isTrue);
    for (final alias in aliases) {
      expect(restored.selectWorld(alias), isTrue);
      expect(restored.pose.position, session.visits[alias]!.position);
      expect(restored.pose.yaw, session.visits[alias]!.yaw);
    }
  });

  test('corruption leaves live navigation state unchanged', () {
    final session = VrlzWorldSession(bundle);
    session.enterPortal('to_gallery');
    final bytes = session.encodeSnapshot();
    final document = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    document['state']['currentWorld'] = 'garden'; // Preserve the old checksum.
    expect(
      session.restoreSnapshot(
        Uint8List.fromList(utf8.encode(jsonEncode(document))),
      ),
      isFalse,
    );
    expect(session.currentWorld, 'gallery');
    expect(session.restoreSnapshot(Uint8List(20000)), isFalse);
    expect(session.restoreSnapshot(Uint8List.fromList([1, 2, 3])), isFalse);
  });

  test('revision and exact content changes invalidate older snapshots', () {
    final snapshot = VrlzWorldSession(bundle).encodeSnapshot();
    for (final key in ['revision', 'title', 'id']) {
      final fixture = worldFixture();
      fixture.manifest[key] = key == 'id' ? 'test.other' : 'changed';
      final changed = VrlzWorldBundle.decode(
        VrlzWorldBundle.encode(fixture.manifest, fixture.files),
      );
      final session = VrlzWorldSession(changed);
      expect(session.restoreSnapshot(snapshot), isFalse, reason: key);
      expect(session.currentWorld, 'garden');
    }
  });

  test(
    'even checksummed saves reject foreign aliases and out-of-world poses',
    () {
      final session = VrlzWorldSession(bundle);
      final valid = session.encodeSnapshot();
      final wrongAlias = VrlzWorldSnapshot.decode(valid);
      wrongAlias['currentWorld'] = 'outside';
      (wrongAlias['visits'] as Map)['outside'] = {
        'position': [2, 1.6, 2],
        'yaw': 0,
      };
      expect(
        session.restoreSnapshot(VrlzWorldSnapshot.encode(wrongAlias)),
        isFalse,
      );
      final outside = VrlzWorldSnapshot.decode(valid);
      outside['visits']['garden']['position'] = [-2, 1.6, -2];
      expect(
        session.restoreSnapshot(VrlzWorldSnapshot.encode(outside)),
        isFalse,
      );
      expect(session.pose.position, [2, 1.6, 2]);
    },
  );

  test(
    'movement rejects invalid coordinates and normalizes long-running yaw',
    () {
      final session = VrlzWorldSession(bundle);
      expect(
        () => session.updatePose(
          const VrlzWorldPose(x: double.nan, y: 1.6, z: 2, yaw: 0),
        ),
        throwsFormatException,
      );
      expect(
        () => session.updatePose(
          const VrlzWorldPose(x: 100, y: 1.6, z: 2, yaw: 0),
        ),
        throwsFormatException,
      );
      session.updatePose(const VrlzWorldPose(x: 2, y: 1.6, z: 2, yaw: 1000));
      expect(session.pose.yaw.abs(), lessThan(3.142));
      expect(
        VrlzWorldSession(bundle).restoreSnapshot(session.encodeSnapshot()),
        isTrue,
      );
    },
  );

  test(
    'snapshot structural rules reject extra, malformed, and nonfinite fields',
    () {
      final snapshot = VrlzWorldSession(bundle).encodeSnapshot();
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (state) => state['schema'] = 1.0,
        (state) => state['extra'] = true,
        (state) => state['sequence'] = -1,
        (state) => state['savedAtMicros'] = -1,
        (state) => state['visits']['garden']['extra'] = 3,
        (state) => state['visits']['garden']['yaw'] = 99,
        (state) => state['visits']['garden']['position'] = [1, 2],
      ]) {
        final state = VrlzWorldSnapshot.decode(snapshot);
        mutate(state);
        expect(() => VrlzWorldSnapshot.encode(state), throwsFormatException);
      }
    },
  );
}
