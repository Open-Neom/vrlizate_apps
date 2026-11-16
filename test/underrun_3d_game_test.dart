import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';
import 'package:vrlizate_apps/vrlizate_apps.dart';

void main() {
  group('Underrun3dGame (MIT levels + PhysicsWorldSpace)', () {
    test(
      'loads all 3 authentic 64x64 sectors with exact CPU & sentry counts and spawn safety',
      () {
        final expectedCpus = {1: 9, 2: 9, 3: 8};
        final expectedSentries = {1: 1, 2: 2, 3: 4};

        final game = Underrun3dGame(initialSector: 1);
        for (final sector in [1, 2, 3]) {
          game.loadSector(sector);
          expect(game.sector, sector);
          expect(game.cpusTotal, expectedCpus[sector], reason: 'Sector $sector');

          final sentries = game.enemies
              .where((e) => e.kind == UnderrunEnemyKind.sentry)
              .toList();
          final spiders = game.enemies
              .where((e) => e.kind == UnderrunEnemyKind.spider)
              .toList();
          expect(
            sentries.length,
            expectedSentries[sector],
            reason: 'Sector $sector sentries',
          );
          expect(spiders, isNotEmpty, reason: 'Sector $sector spiders');
          expect(game.walls, isNotEmpty);
          expect(game.isWalkableWorld(game.playerX, game.playerZ), isTrue);

          // Authentic spawn safety: no spider spawns closer than 16 m to player!
          for (final spider in spiders) {
            final dx = spider.x - game.playerX;
            final dz = spider.z - game.playerZ;
            expect(math.sqrt(dx * dx + dz * dz), greaterThanOrEqualTo(16.0));
          }
        }
      },
    );

    test(
      'wall OBBs block character movement and stop plasma bolts via PhysicsWorldSpace.raycast',
      () {
        final game = Underrun3dGame(initialSector: 1);
        final startX = game.playerX;
        final startZ = game.playerZ;

        // Walk persistently into the north boundary until hitting a wall OBB.
        for (var i = 0; i < 120; i++) {
          game.step(
            1.0 / 60.0,
            const UnderrunInputFrame(moveZ: -1.0, aimYawRadians: math.pi),
          );
        }
        expect(game.isWalkableWorld(game.playerX, game.playerZ), isTrue);
        expect(
          (game.playerX - startX).abs() + (game.playerZ - startZ).abs(),
          greaterThan(0.5),
        );

        // Fire plasma straight into the adjacent north wall (`yaw = pi` -> `-Z`)
        // and verify raycast expires the bolt cleanly without crossing void cells.
        game.step(
          1.0 / 60.0,
          const UnderrunInputFrame(aimYawRadians: math.pi, firePressed: true),
        );
        for (var i = 0; i < 40; i++) {
          game.step(1.0 / 60.0, const UnderrunInputFrame());
          for (final b in game.bolts) {
            expect(game.isWalkableWorld(b.x, b.z), isTrue);
          }
        }
        expect(game.bolts, isEmpty);
      },
    );

    test('plasma bolts damage and eliminate enemies and increment kill count', () {
      final game = Underrun3dGame(initialSector: 1);
      final target = game.enemies.firstWhere(
        (e) => e.kind == UnderrunEnemyKind.spider,
      );
      // Find an open walkable cardinal direction right next to player spawn:
      const dirs = <(double dx, double dz, double yaw)>[
        (0.0, -1.5, math.pi),
        (0.0, 1.5, 0.0),
        (1.5, 0.0, math.pi * 0.5),
        (-1.5, 0.0, -math.pi * 0.5),
      ];
      final chosen = dirs.firstWhere(
        (d) =>
            game.isWalkableWorld(game.playerX + d.$1, game.playerZ + d.$2) &&
            !game.physicsSpace.isSegmentOccluded(
              Vector3(game.playerX, 1.15, game.playerZ),
              Vector3(game.playerX + d.$1, 1.15, game.playerZ + d.$2),
            ),
      );
      target
        ..x = game.playerX + chosen.$1
        ..z = game.playerZ + chosen.$2
        ..targetX = game.playerX + chosen.$1
        ..targetZ = game.playerZ + chosen.$2
        ..retargetCooldown = 99.0;

      for (var tick = 0; tick < 60 && target.isAlive; tick++) {
        game.step(
          1.0 / 60.0,
          UnderrunInputFrame(aimYawRadians: chosen.$3, firePressed: true),
        );
      }
      expect(target.isAlive, isFalse);
      expect(game.kills, greaterThanOrEqualTo(1));
    });

    test(
      'rebooting all CPUs advances Sector 1 -> Sector 2 -> Sector 3 -> campaignCompleted',
      () {
        final game = Underrun3dGame(initialSector: 1);

        for (final expectedSector in [1, 2, 3]) {
          expect(game.sector, expectedSector);
          expect(game.campaignCompleted, isFalse);

          for (final cpu in game.cpus) {
            game.placePlayerAt(cpu.x + 0.9, cpu.z);
            game.step(1.0 / 60.0, const UnderrunInputFrame());
            expect(cpu.rebooted, isTrue);
          }
          expect(game.cpusRebooted, game.cpusTotal);

          // Advance past the 1.6s sector transition timer.
          for (var i = 0; i < 36; i++) {
            game.step(0.05, const UnderrunInputFrame());
          }
        }

        expect(game.sector, 3);
        expect(game.campaignCompleted, isTrue);
      },
    );
  });
}
