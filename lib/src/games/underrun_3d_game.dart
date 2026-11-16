// ============================================================================
// Native 3D VR simulation engine for UNDERRUN (3 sectors, twin-stick combat).
// Level layouts & gameplay rules adapted from UNDERRUN by Dominic Szablewski
// (Copyright (c) 2018 Dominic Szablewski, https://phoboslab.org, MIT License),
// powered by VRlizate's PhysicsWorldSpace (`vrlizate_physics`) OBB sliding,
// analytical raycasts, and trigger colliders.
// ============================================================================

import 'dart:math' as math;

import 'package:vector_math/vector_math.dart';
import 'package:vrlizate_physics/vrlizate_physics.dart';

import 'underrun_3d_levels.dart';

enum UnderrunEnemyKind { spider, sentry }

final class UnderrunWallSegment {
  const UnderrunWallSegment({
    required this.id,
    required this.centerX,
    required this.centerZ,
    required this.widthMeters,
    required this.depthMeters,
    required this.heightMeters,
  });

  final String id;
  final double centerX;
  final double centerZ;
  final double widthMeters;
  final double depthMeters;
  final double heightMeters;
}

final class UnderrunCpuTerminal {
  UnderrunCpuTerminal({
    required this.id,
    required this.gridX,
    required this.gridZ,
    required this.x,
    required this.z,
    this.rebooted = false,
  });

  final String id;
  final int gridX;
  final int gridZ;
  final double x;
  final double z;
  bool rebooted;
}

final class UnderrunEnemy {
  UnderrunEnemy({
    required this.id,
    required this.kind,
    required this.x,
    required this.z,
    required this.health,
  }) : targetX = x,
       targetZ = z;

  final String id;
  final UnderrunEnemyKind kind;
  double x;
  double z;
  double vx = 0.0;
  double vz = 0.0;
  int health;
  double targetX;
  double targetZ;
  double retargetCooldown = 0.0;
  double fireCooldown = 0.4;
  double hitFlash = 0.0;

  bool get isAlive => health > 0;
  double get hitRadius => kind == UnderrunEnemyKind.sentry ? 0.85 : 0.65;
}

final class UnderrunMedkit {
  UnderrunMedkit({
    required this.id,
    required this.x,
    required this.z,
    this.collected = false,
  });

  final String id;
  final double x;
  final double z;
  bool collected;
}

final class UnderrunPlasmaBolt {
  UnderrunPlasmaBolt({
    required this.id,
    required this.fromPlayer,
    required this.x,
    required this.y,
    required this.z,
    required this.vx,
    required this.vz,
    this.remainingSeconds = 1.4,
  });

  final int id;
  final bool fromPlayer;
  double x;
  double y;
  double z;
  final double vx;
  final double vz;
  double remainingSeconds;
  bool expired = false;
}

/// Deterministic 32-bit PRNG matching `underrun/source/random.js`.
final class _UnderrunPrng {
  _UnderrunPrng(int seed) {
    _high = (seed == 0 ? 0xBADC0FFE : seed) & 0xffffffff;
    _low = (_high ^ 0x49616E42) & 0xffffffff;
  }

  late int _high;
  late int _low;

  int nextIntInclusive(int min, int max) {
    final h16L = (_high << 16) & 0xffffffff;
    final h16R = (_high >> 16) & 0xffff;
    // Match signed 32-bit JS `>> 16` sign extension when bit 31 is set:
    final signedShift = (_high & 0x80000000) != 0 ? (h16R | 0xffff0000) : h16R;
    _high = (h16L + signedShift + _low) & 0xffffffff;
    _low = (_low + _high) & 0xffffffff;
    final n = _high / 0xffffffff;
    return (min + n * (max - min + 1)).floor().clamp(min, max);
  }

  double nextUnit() {
    nextIntInclusive(0, 1000);
    return _high / 0xffffffff;
  }
}

/// Twin-stick + VR gaze/laser input frame for one [Underrun3dGame.step] tick.
final class UnderrunInputFrame {
  const UnderrunInputFrame({
    this.moveX = 0.0,
    this.moveZ = 0.0,
    this.aimYawRadians,
    this.firePressed = false,
  });

  /// World/camera-projected strafe (`-1..1`, `+X` right).
  final double moveX;

  /// World/camera-projected forward/back (`-1..1`, `-Z` north / `+Z` south).
  final double moveZ;

  /// Desired horizontal firing yaw in world space (`atan2(dx, dz)` so `0` faces `+Z`,
  /// `pi` faces `-Z`, `+pi/2` faces `+X`), or `null` to keep current aim.
  final double? aimYawRadians;

  final bool firePressed;
}

/// Complete deterministic 3D simulation for all 3 `UNDERRUN` sectors backed by
/// [PhysicsWorldSpace] (`vrlizate_physics`).
final class Underrun3dGame {
  Underrun3dGame({int initialSector = 1}) {
    loadSector(initialSector);
  }

  static const double tileMeters = 2.0;
  static const double wallHeightMeters = 2.5;
  static const double eyeHeightMeters = 1.6;
  static const int maxPlayerHealth = 5;
  static const double playerMoveSpeed = 7.2;
  static const double playerShotInterval = 0.10;
  static const double playerBoltSpeed = 24.0;
  static const double sentryBoltSpeed = 15.5;
  static const double playerInvulnerabilitySeconds = 1.6;

  final PhysicsWorldSpace physicsSpace = PhysicsWorldSpace(
    groundY: 0.0,
    eyeHeight: eyeHeightMeters,
    characterHeight: 1.8,
    bodyRadius: 0.42,
    maxStepHeight: 0.25,
  );

  int _sector = 1;
  late _UnderrunPrng _rng;
  final List<bool> _walkable = List<bool>.filled(
    Underrun3dLevels.gridSize * Underrun3dLevels.gridSize,
    false,
  );
  final List<(int x, int z)> _floorTiles = <(int, int)>[];
  final List<UnderrunWallSegment> _walls = <UnderrunWallSegment>[];
  final List<UnderrunCpuTerminal> _cpus = <UnderrunCpuTerminal>[];
  final List<UnderrunEnemy> _enemies = <UnderrunEnemy>[];
  final List<UnderrunMedkit> _medkits = <UnderrunMedkit>[];
  final List<UnderrunPlasmaBolt> _bolts = <UnderrunPlasmaBolt>[];

  Vector3 _playerEye = Vector3(0, eyeHeightMeters, 0);
  double _aimYawRadians = 0.0;
  int _playerHealth = maxPlayerHealth;
  double _shotCooldown = 0.0;
  double _damageImmunity = 0.0;
  double _cameraShake = 0.0;
  double _sectorAdvanceTimer = -1.0;
  double _respawnTimer = -1.0;
  int _cpusRebooted = 0;
  int _kills = 0;
  int _nextBoltId = 1;
  bool _campaignCompleted = false;
  String _terminalNotice = '';
  double _noticeRemainingSeconds = 0.0;

  int get sector => _sector;
  Vector3 get playerEye => _playerEye.clone();
  double get playerX => _playerEye.x;
  double get playerZ => _playerEye.z;
  double get aimYawRadians => _aimYawRadians;
  int get playerHealth => _playerHealth;
  bool get isPlayerDead => _playerHealth <= 0;
  bool get isPlayerDamageFlashing => _damageImmunity > 0.0;
  double get cameraShake => _cameraShake;
  int get cpusTotal => _cpus.length;
  int get cpusRebooted => _cpusRebooted;
  int get kills => _kills;
  bool get campaignCompleted => _campaignCompleted;
  String get terminalNotice => _terminalNotice;
  double get noticeRemainingSeconds => _noticeRemainingSeconds;

  List<(int x, int z)> get floorTiles => List.unmodifiable(_floorTiles);
  List<UnderrunWallSegment> get walls => List.unmodifiable(_walls);
  List<UnderrunCpuTerminal> get cpus => List.unmodifiable(_cpus);
  List<UnderrunEnemy> get enemies => List.unmodifiable(_enemies);
  List<UnderrunMedkit> get medkits => List.unmodifiable(_medkits);
  List<UnderrunPlasmaBolt> get bolts => List.unmodifiable(_bolts);

  static double cellCenter(int gridCoord) => (gridCoord + 0.5) * tileMeters;

  bool isWalkableCell(int gx, int gz) {
    if (gx < 0 ||
        gz < 0 ||
        gx >= Underrun3dLevels.gridSize ||
        gz >= Underrun3dLevels.gridSize) {
      return false;
    }
    return _walkable[gz * Underrun3dLevels.gridSize + gx];
  }

  bool isWalkableWorld(double x, double z) =>
      isWalkableCell((x / tileMeters).floor(), (z / tileMeters).floor());

  /// Repositions the player eye on the horizontal XZ plane (used by tests and
  /// sector arrival teleports).
  void placePlayerAt(double x, double z) {
    _playerEye = Vector3(x, eyeHeightMeters, z);
  }

  /// Loads sector `1`, `2`, or `3`, rebuilding greedy-merged wall OBBs and CPU
  /// trigger volumes inside [physicsSpace].
  void loadSector(int nextSector) {
    final rows = Underrun3dLevels.sectorRows(nextSector);
    _sector = nextSector;
    _rng = _UnderrunPrng(0xBADC0DE1 + nextSector);
    _walkable.fillRange(0, _walkable.length, false);
    _floorTiles.clear();
    _walls.clear();
    _cpus.clear();
    _enemies.clear();
    _medkits.clear();
    _bolts.clear();

    _playerHealth = maxPlayerHealth;
    _shotCooldown = 0.0;
    _damageImmunity = 0.0;
    _cameraShake = 0.0;
    _sectorAdvanceTimer = -1.0;
    _respawnTimer = -1.0;
    _cpusRebooted = 0;
    _campaignCompleted = false;

    final isWallGrid = List<bool>.filled(
      Underrun3dLevels.gridSize * Underrun3dLevels.gridSize,
      false,
    );

    var spawnX = cellCenter(32);
    var spawnZ = cellCenter(32);
    var spiderCounter = 0;
    var sentryCounter = 0;
    var medkitCounter = 0;

    for (var gz = 0; gz < Underrun3dLevels.gridSize; gz++) {
      final row = rows[gz];
      for (var gx = 0; gx < Underrun3dLevels.gridSize; gx++) {
        final ch = row[gx];
        if (ch == '.') continue;
        final idx = gz * Underrun3dLevels.gridSize + gx;
        final wx = cellCenter(gx);
        final wz = cellCenter(gz);

        if (ch == '#') {
          isWallGrid[idx] = true;
          continue;
        }

        // Walkable interior cell (' ', 'C', 'S', 'P')
        _walkable[idx] = true;
        _floorTiles.add((gx, gz));

        if (ch == ' ') {
          if (_rng.nextIntInclusive(0, 16 - nextSector * 2) == 0) {
            _enemies.add(
              UnderrunEnemy(
                id: 'spider_${++spiderCounter}',
                kind: UnderrunEnemyKind.spider,
                x: wx,
                z: wz,
                health: 5,
              ),
            );
          } else if (_rng.nextIntInclusive(0, 100) == 0) {
            _medkits.add(
              UnderrunMedkit(
                id: 'medkit_${++medkitCounter}',
                x: wx,
                z: wz,
              ),
            );
          }
        } else if (ch == 'C') {
          _cpus.add(
            UnderrunCpuTerminal(
              id: 'cpu_${_cpus.length}',
              gridX: gx,
              gridZ: gz,
              x: wx,
              z: wz,
            ),
          );
        } else if (ch == 'S') {
          _enemies.add(
            UnderrunEnemy(
              id: 'sentry_${++sentryCounter}',
              kind: UnderrunEnemyKind.sentry,
              x: wx,
              z: wz,
              health: 20,
            ),
          );
        } else if (ch == 'P') {
          spawnX = wx;
          spawnZ = wz;
        }
      }
    }

    // Remove spiders within 8 tiles (16 m) of player spawn (matching game.js).
    const safeRadius = 8.0 * tileMeters;
    _enemies.removeWhere(
      (e) =>
          e.kind == UnderrunEnemyKind.spider &&
          (e.x - spawnX).abs() < safeRadius &&
          (e.z - spawnZ).abs() < safeRadius,
    );

    // Greedy-merge contiguous horizontal wall runs into box colliders.
    final colliders = <PhysicsWorldCollider>[];
    var wallId = 0;
    for (var gz = 0; gz < Underrun3dLevels.gridSize; gz++) {
      var gx = 0;
      while (gx < Underrun3dLevels.gridSize) {
        if (!isWallGrid[gz * Underrun3dLevels.gridSize + gx]) {
          gx++;
          continue;
        }
        final startX = gx;
        while (gx < Underrun3dLevels.gridSize &&
            isWallGrid[gz * Underrun3dLevels.gridSize + gx]) {
          gx++;
        }
        final runCells = gx - startX;
        final width = runCells * tileMeters;
        final cx = (startX + runCells * 0.5) * tileMeters;
        final cz = cellCenter(gz);
        final id = 'wall_${++wallId}';
        _walls.add(
          UnderrunWallSegment(
            id: id,
            centerX: cx,
            centerZ: cz,
            widthMeters: width,
            depthMeters: tileMeters,
            heightMeters: wallHeightMeters,
          ),
        );
        colliders.add(
          PhysicsWorldCollider(
            id: id,
            shape: PhysicsColliderShape.box,
            center: Vector3(cx, wallHeightMeters * 0.5, cz),
            halfExtents: Vector3(
              width * 0.5,
              wallHeightMeters * 0.5,
              tileMeters * 0.5,
            ),
          ),
        );
      }
    }

    // Add CPU monolith solid pillars + reboot proximity trigger spheres.
    for (final cpu in _cpus) {
      colliders.add(
        PhysicsWorldCollider(
          id: '${cpu.id}_pillar',
          shape: PhysicsColliderShape.box,
          center: Vector3(cpu.x, 1.1, cpu.z),
          halfExtents: Vector3(0.55, 1.1, 0.55),
        ),
      );
      colliders.add(
        PhysicsWorldCollider(
          id: cpu.id,
          shape: PhysicsColliderShape.sphere,
          center: Vector3(cpu.x, 1.1, cpu.z),
          radius: 1.55,
          isTrigger: true,
        ),
      );
    }

    physicsSpace.replaceColliders(colliders);
    physicsSpace.resetCharacterState(grounded: true);
    _playerEye = Vector3(spawnX, eyeHeightMeters, spawnZ);
    _aimYawRadians = math.pi; // Face north (-Z) by default.
    _postNotice(
      'SECTOR $_sector · SCANNING OFFLINE TERMINALS... ${_cpus.length} FOUND',
    );
  }

  void _postNotice(String text, {double durationSeconds = 4.0}) {
    _terminalNotice = text;
    _noticeRemainingSeconds = durationSeconds;
  }

  /// Immediately advances to the next sector (or completes campaign after 3).
  void advanceSector() {
    if (_sector >= Underrun3dLevels.sectorCount) {
      _campaignCompleted = true;
      _sectorAdvanceTimer = -1.0;
      _postNotice(
        'ALL SECTORS ONLINE · FACILITY REBOOT COMPLETE!',
        durationSeconds: 10.0,
      );
    } else {
      loadSector(_sector + 1);
    }
  }

  /// Advances the 3D game world by [dt] seconds.
  void step(double dt, UnderrunInputFrame input) {
    if (!dt.isFinite || dt <= 0.0) return;
    final safeDt = math.min(dt, 0.05);

    if (_noticeRemainingSeconds > 0.0) {
      _noticeRemainingSeconds = math.max(0.0, _noticeRemainingSeconds - safeDt);
    }
    _cameraShake = _cameraShake * math.pow(0.08, safeDt).toDouble();
    if (_cameraShake < 1e-3) _cameraShake = 0.0;

    if (_campaignCompleted) return;

    if (_respawnTimer > 0.0) {
      _respawnTimer -= safeDt;
      if (_respawnTimer <= 0.0) {
        loadSector(_sector);
      }
      return;
    }

    if (_sectorAdvanceTimer > 0.0) {
      _sectorAdvanceTimer -= safeDt;
      if (_sectorAdvanceTimer <= 0.0) {
        advanceSector();
        return;
      }
    }

    if (_damageImmunity > 0.0) {
      _damageImmunity = math.max(0.0, _damageImmunity - safeDt);
    }
    if (_shotCooldown > 0.0) {
      _shotCooldown = math.max(0.0, _shotCooldown - safeDt);
    }

    // 1. Player movement & CPU terminal trigger detection via PhysicsWorldSpace.
    var mx = input.moveX.isFinite ? input.moveX.clamp(-1.0, 1.0) : 0.0;
    var mz = input.moveZ.isFinite ? input.moveZ.clamp(-1.0, 1.0) : 0.0;
    final mag = math.sqrt(mx * mx + mz * mz);
    if (mag > 1.0) {
      mx /= mag;
      mz /= mag;
    }

    if (input.aimYawRadians != null && input.aimYawRadians!.isFinite) {
      _aimYawRadians = input.aimYawRadians!;
    } else if (mag > 0.15) {
      _aimYawRadians = math.atan2(mx, mz);
    }

    final desiredEye = Vector3(
      _playerEye.x + mx * playerMoveSpeed * safeDt,
      _playerEye.y,
      _playerEye.z + mz * playerMoveSpeed * safeDt,
    );

    final stepResult = physicsSpace.stepEyePosition(
      previousEye: _playerEye,
      desiredEye: desiredEye,
      dt: safeDt,
      applyGravity: false,
      isCellValid: isWalkableWorld,
    );
    _playerEye = stepResult.eyePosition;

    for (final triggerId in stepResult.enteredTriggers) {
      _tryRebootCpu(triggerId);
    }
    // Also check radial proximity in case player spawned inside trigger radius.
    for (final cpu in _cpus) {
      if (!cpu.rebooted) {
        final dx = cpu.x - _playerEye.x;
        final dz = cpu.z - _playerEye.z;
        if (dx * dx + dz * dz <= 1.65 * 1.65) {
          _tryRebootCpu(cpu.id);
        }
      }
    }

    // 2. Medkit pickups.
    if (_playerHealth < maxPlayerHealth) {
      for (final med in _medkits) {
        if (med.collected) continue;
        final dx = med.x - _playerEye.x;
        final dz = med.z - _playerEye.z;
        if (dx * dx + dz * dz <= 1.15 * 1.15) {
          med.collected = true;
          _playerHealth = math.min(maxPlayerHealth, _playerHealth + 1);
          _postNotice('NANOMED RESTORED · INTEGRITY $_playerHealth/$maxPlayerHealth');
        }
      }
    }

    // 3. Player plasma weapon firing.
    if (input.firePressed && _shotCooldown <= 0.0) {
      _shotCooldown = playerShotInterval;
      final spread = (_rng.nextUnit() - 0.5) * 0.08;
      final angle = _aimYawRadians + spread;
      final dirX = math.sin(angle);
      final dirZ = math.cos(angle);
      _bolts.add(
        UnderrunPlasmaBolt(
          id: _nextBoltId++,
          fromPlayer: true,
          x: _playerEye.x + dirX * 0.55,
          y: 1.15,
          z: _playerEye.z + dirZ * 0.55,
          vx: dirX * playerBoltSpeed,
          vz: dirZ * playerBoltSpeed,
        ),
      );
    }

    // 4. Update enemies (Spiders & Sentries).
    _stepEnemies(safeDt);

    // 5. Step plasma bolts with PhysicsWorldSpace.raycast + sphere hit tests.
    _stepBolts(safeDt);
  }

  void _tryRebootCpu(String triggerId) {
    for (final cpu in _cpus) {
      if (cpu.id == triggerId && !cpu.rebooted) {
        cpu.rebooted = true;
        _cpusRebooted++;
        final remaining = _cpus.length - _cpusRebooted;
        if (remaining > 0) {
          _postNotice('REBOOTING TERMINAL... SUCCESS · $remaining OFFLINE');
        } else {
          _sectorAdvanceTimer = 1.6;
          _postNotice(
            _sector < Underrun3dLevels.sectorCount
                ? 'ALL SYSTEMS ONLINE · TRIANGULATING NEXT SECTOR...'
                : 'ALL SYSTEMS ONLINE · FINAL CORE STABILIZED!',
          );
        }
        return;
      }
    }
  }

  void _stepEnemies(double dt) {
    for (var i = 0; i < _enemies.length; i++) {
      final enemy = _enemies[i];
      if (!enemy.isAlive) continue;
      if (enemy.hitFlash > 0.0) {
        enemy.hitFlash = math.max(0.0, enemy.hitFlash - dt);
      }

      final dxPlayer = _playerEye.x - enemy.x;
      final dzPlayer = _playerEye.z - enemy.z;
      final distPlayer = math.sqrt(dxPlayer * dxPlayer + dzPlayer * dzPlayer);

      enemy.retargetCooldown -= dt;
      if (enemy.retargetCooldown <= 0.0 && distPlayer < 16.0) {
        enemy.retargetCooldown = 0.3 + _rng.nextUnit() * 0.45;
        enemy.targetX = _playerEye.x;
        enemy.targetZ = _playerEye.z;
      }

      if (enemy.kind == UnderrunEnemyKind.sentry) {
        enemy.fireCooldown -= dt;
        if (enemy.fireCooldown <= 0.0 && distPlayer < 12.5 && distPlayer > 0.4) {
          enemy.fireCooldown = 0.65 + _rng.nextUnit() * 0.35;
          final origin = Vector3(enemy.x, 1.15, enemy.z);
          final target = Vector3(_playerEye.x, 1.15, _playerEye.z);
          if (!physicsSpace.isSegmentOccluded(origin, target)) {
            final baseYaw = math.atan2(dxPlayer, dzPlayer);
            final yaw = baseYaw + (_rng.nextUnit() - 0.5) * 0.12;
            _bolts.add(
              UnderrunPlasmaBolt(
                id: _nextBoltId++,
                fromPlayer: false,
                x: enemy.x + math.sin(yaw) * 0.65,
                y: 1.15,
                z: enemy.z + math.cos(yaw) * 0.65,
                vx: math.sin(yaw) * sentryBoltSpeed,
                vz: math.cos(yaw) * sentryBoltSpeed,
                remainingSeconds: 1.8,
              ),
            );
          }
        }
      }

      final moveAccel = enemy.kind == UnderrunEnemyKind.spider
          ? 24.0
          : (distPlayer > 6.0 ? 8.0 : 0.0);
      final toTargetX = enemy.targetX - enemy.x;
      final toTargetZ = enemy.targetZ - enemy.z;
      final toTargetLen = math.sqrt(
        toTargetX * toTargetX + toTargetZ * toTargetZ,
      );
      final ax = toTargetLen > 0.35 ? (toTargetX / toTargetLen) * moveAccel : 0.0;
      final az = toTargetLen > 0.35 ? (toTargetZ / toTargetLen) * moveAccel : 0.0;

      final drag = math.min(5.0 * dt, 1.0);
      enemy.vx += ax * dt - enemy.vx * drag;
      enemy.vz += az * dt - enemy.vz * drag;

      // Spider-to-spider separation so swarms fan out in corridors.
      for (var j = i + 1; j < _enemies.length; j++) {
        final other = _enemies[j];
        if (!other.isAlive) continue;
        final sx = enemy.x - other.x;
        final sz = enemy.z - other.z;
        final d2 = sx * sx + sz * sz;
        if (d2 > 1e-6 && d2 < 1.2 * 1.2) {
          final inv = 1.0 / math.sqrt(d2);
          final push = 4.0 * dt;
          enemy.vx += sx * inv * push;
          enemy.vz += sz * inv * push;
          other.vx -= sx * inv * push;
          other.vz -= sz * inv * push;
        }
      }

      final nextX = enemy.x + enemy.vx * dt;
      final nextZ = enemy.z + enemy.vz * dt;
      if (isWalkableWorld(nextX, enemy.z)) {
        enemy.x = nextX;
      } else {
        enemy.vx = 0.0;
      }
      if (isWalkableWorld(enemy.x, nextZ)) {
        enemy.z = nextZ;
      } else {
        enemy.vz = 0.0;
      }

      // Spider melee contact against player.
      if (enemy.kind == UnderrunEnemyKind.spider && distPlayer < 1.05) {
        enemy.vx = -dxPlayer * 3.5;
        enemy.vz = -dzPlayer * 3.5;
        _damagePlayer(1);
      }
    }
    _enemies.removeWhere((e) => !e.isAlive);
  }

  void _stepBolts(double dt) {
    final origin = Vector3.zero();
    final dir = Vector3.zero();

    for (final bolt in _bolts) {
      if (bolt.expired) continue;
      bolt.remainingSeconds -= dt;
      if (bolt.remainingSeconds <= 0.0) {
        bolt.expired = true;
        continue;
      }

      final stepX = bolt.vx * dt;
      final stepZ = bolt.vz * dt;
      final stepDist = math.sqrt(stepX * stepX + stepZ * stepZ);
      if (stepDist <= 1e-6) continue;

      origin.setValues(bolt.x, bolt.y, bolt.z);
      dir.setValues(stepX / stepDist, 0.0, stepZ / stepDist);

      final wallHit = physicsSpace.raycast(
        origin,
        dir,
        maxDistance: stepDist + 0.12,
      );
      if (wallHit != null) {
        bolt.expired = true;
        continue;
      }

      final nx = bolt.x + stepX;
      final nz = bolt.z + stepZ;
      if (!isWalkableWorld(nx, nz)) {
        bolt.expired = true;
        continue;
      }
      bolt.x = nx;
      bolt.z = nz;

      if (bolt.fromPlayer) {
        for (final enemy in _enemies) {
          if (!enemy.isAlive) continue;
          final dx = enemy.x - bolt.x;
          final dz = enemy.z - bolt.z;
          final r = enemy.hitRadius + 0.22;
          if (dx * dx + dz * dz <= r * r) {
            bolt.expired = true;
            enemy.health -= 1;
            enemy.hitFlash = 0.12;
            final knock = enemy.kind == UnderrunEnemyKind.spider ? 0.35 : 0.08;
            enemy.vx += bolt.vx * knock;
            enemy.vz += bolt.vz * knock;
            if (!enemy.isAlive) {
              _kills++;
              _cameraShake = math.max(
                _cameraShake,
                enemy.kind == UnderrunEnemyKind.sentry ? 0.45 : 0.18,
              );
            }
            break;
          }
        }
      } else {
        final dx = _playerEye.x - bolt.x;
        final dz = _playerEye.z - bolt.z;
        if (dx * dx + dz * dz <= 0.68 * 0.68) {
          bolt.expired = true;
          _damagePlayer(1);
        }
      }
    }
    _bolts.removeWhere((b) => b.expired);
  }

  void _damagePlayer(int amount) {
    if (_damageImmunity > 0.0 || _playerHealth <= 0) return;
    _playerHealth = math.max(0, _playerHealth - amount);
    _damageImmunity = playerInvulnerabilitySeconds;
    _cameraShake = math.max(_cameraShake, 0.35);
    if (_playerHealth <= 0) {
      _respawnTimer = 2.4;
      _postNotice('DEPLOYMENT FAILED · RESTORING SECTOR BACKUP...');
    }
  }
}
