import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;
import 'package:vrlizate_scene/vrlizate_scene.dart';

import '../games/underrun_3d_game.dart';

/// Native 3D VR + Tactical Chase viewer for **`UNDERRUN`** (`MIT` level design
/// by Dominic Szablewski) built on `StereoSceneView` (`flutter_scene`),
/// `PhysicsWorldSpace` (`vrlizate_physics`), `SGSR 1` (`0.75x -> 1.0x`), and
/// VRlizate twin-stick BLE / Hybrid UDP / keyboard / touch controls.
class Underrun3dViewer extends StatelessWidget {
  const Underrun3dViewer({
    super.key,
    this.onExit,
    this.initialTacticalChaseView = false,
    this.sgsrUpscale = VrSgsrUpscaleConfig.mobileBalanced,
    this.quality,
  });

  final VoidCallback? onExit;
  final bool initialTacticalChaseView;
  final VrSgsrUpscaleConfig? sgsrUpscale;
  final VrQualityPreset? quality;

  @override
  Widget build(BuildContext context) => VrGpuResourceGate(
    onBack: onExit,
    builder: (_) => _Underrun3dPlayer(
      onExit: onExit,
      initialTacticalChaseView: initialTacticalChaseView,
      sgsrUpscale: sgsrUpscale,
      quality: quality,
    ),
  );
}

class _Underrun3dPlayer extends StatefulWidget {
  const _Underrun3dPlayer({
    this.onExit,
    required this.initialTacticalChaseView,
    this.sgsrUpscale,
    this.quality,
  });

  final VoidCallback? onExit;
  final bool initialTacticalChaseView;
  final VrSgsrUpscaleConfig? sgsrUpscale;
  final VrQualityPreset? quality;

  @override
  State<_Underrun3dPlayer> createState() => _Underrun3dPlayerState();
}

class _Underrun3dPlayerState extends State<_Underrun3dPlayer> {
  final Underrun3dGame _game = Underrun3dGame(initialSector: 1);
  final fs.Scene _scene = fs.Scene();
  late final StereoHeadRig _rig = StereoHeadRig(
    eyeCenter: _game.playerEye,
    convergenceDistance: 2.2,
  );
  final FocusNode _keyboardFocus = FocusNode(debugLabel: 'underrun_3d_keys');

  VrInputArbiter? _arbiter;
  int _builtSector = -1;
  late bool _tacticalChaseView = widget.initialTacticalChaseView;

  // Arbiter / twin-stick / keyboard input state
  double _stickMoveX = 0.0;
  double _stickMoveY = 0.0;
  double _stickTurnX = 0.0;
  double _stickTurnY = 0.0;
  bool _remoteFireHeld = false;
  double _fireBurstSeconds = 0.0;
  bool _touchFireHeld = false;
  bool _slowMo = false;
  double _animClock = 0.0;
  final Set<LogicalKeyboardKey> _heldKeys = <LogicalKeyboardKey>{};

  // Retained PBR materials dressed asynchronously off-thread:
  fs.PhysicallyBasedMaterial? _wallMat;
  fs.PhysicallyBasedMaterial? _floorMat;
  fs.PhysicallyBasedMaterial? _cpuBaseMat;

  // Retained InstancedMesh batches (12 total draw calls for the whole 64x64 sector!)
  fs.InstancedMesh? _wallBatch;
  fs.InstancedMesh? _floorBatch;
  fs.InstancedMesh? _cpuPedestalBatch;
  fs.InstancedMesh? _cpuOfflineBatch;
  fs.InstancedMesh? _cpuOnlineBatch;
  fs.InstancedMesh? _spiderBatch;
  fs.InstancedMesh? _spiderLegBatch;
  fs.InstancedMesh? _sentryBaseBatch;
  fs.InstancedMesh? _sentryBatch;
  fs.InstancedMesh? _medkitBatch;
  fs.InstancedMesh? _playerBoltBatch;
  fs.InstancedMesh? _enemyBoltBatch;

  fs.Node? _wallNode;
  fs.Node? _floorNode;
  fs.Node? _cpuPedestalNode;
  fs.Node? _cpuOfflineNode;
  fs.Node? _cpuOnlineNode;
  fs.Node? _spiderNode;
  fs.Node? _spiderLegNode;
  fs.Node? _sentryBaseNode;
  fs.Node? _sentryNode;
  fs.Node? _medkitNode;
  fs.Node? _playerBoltNode;
  fs.Node? _enemyBoltNode;
  fs.Node? _playerAvatarNode;
  fs.Node? _torchNode;

  final ValueNotifier<_HudSnapshot> _hud = ValueNotifier<_HudSnapshot>(
    const _HudSnapshot(
      sector: 1,
      health: 5,
      cpusRebooted: 0,
      cpusTotal: 9,
      kills: 0,
      notice: '',
      completed: false,
    ),
  );

  @override
  void initState() {
    super.initState();
    _initSceneGraph();
    _rebuildStaticSectorMeshes();
    _dressSectorMaterials();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = VrInputSessionScope.arbiterOf(context);
    if (!identical(next, _arbiter)) {
      _arbiter?.removeListener(_onInput);
      _arbiter = next;
      _arbiter?.addListener(_onInput);
    }
  }

  @override
  void dispose() {
    _arbiter?.removeListener(_onInput);
    _keyboardFocus.dispose();
    _hud.dispose();
    _scene.root.removeAll();
    _scene.dispose();
    super.dispose();
  }

  void _initSceneGraph() {
    VrSky.applyGradient(
      _scene,
      VrSky.night(moonDirection: vm.Vector3(-0.25, 1.0, -0.35)),
      intensity: 0.45,
    );

    _scene.add(
      fs.Node()
        ..addComponent(
          fs.DirectionalLightComponent.aimed(
            fs.DirectionalLight(
              intensity: 0.85,
              color: vm.Vector3(0.55, 0.72, 1.0),
            ),
            vm.Vector3(-0.35, -1.0, -0.45),
          ),
        ),
    );

    _torchNode = fs.Node()
      ..addComponent(
        fs.PointLightComponent(
          fs.PointLight(
            color: vm.Vector3(1.0, 0.58, 0.24),
            intensity: 18.0,
          ),
        ),
      );
    _scene.add(_torchNode!);

    final beveledUnit = VrSculptedGeometry.beveledBox(
      vm.Vector3(1, 1, 1),
      cornerRadius: 0.048,
      bevelZ: 0.048,
      cornerSegments: 2,
      bevelSegments: 2,
    );
    final groundedWallUnit = VrSculptedGeometry.beveledBox(
      vm.Vector3(1, 1, 1),
      cornerRadius: 0.048,
      bevelZ: 0.048,
      cornerSegments: 2,
      bevelSegments: 2,
      groundAoStrength: 0.38,
    );
    final crystalGeo = VrSculptedGeometry.facetedCrystal(
      radius: 0.34,
      height: 0.86,
      sides: 6,
    );
    final cpuPedestalGeo = VrSculptedGeometry.flutedPedestal(
      bottomRadius: 0.54,
      topRadius: 0.42,
      height: 1.24,
      segments: 18,
      groundAoStrength: 0.36,
    );
    final spiderCarapaceGeo = VrSculptedGeometry.octaCore(
      radius: 0.44,
      verticalScale: 0.72,
    );
    final spiderLegsGeo = VrSculptedGeometry.beveledBox(
      vm.Vector3(1.18, 0.14, 0.20),
      cornerRadius: 0.045,
      bevelZ: 0.045,
    );
    final sentryBaseGeo = VrSculptedGeometry.flutedPedestal(
      bottomRadius: 0.56,
      topRadius: 0.40,
      height: 1.12,
      segments: 16,
      groundAoStrength: 0.36,
    );
    final sentryHeadGeo = VrSculptedGeometry.beveledBox(
      vm.Vector3(0.76, 0.48, 0.96),
      cornerRadius: 0.11,
      bevelZ: 0.10,
    );
    final medkitPodGeo = VrSculptedGeometry.capsule(
      radius: 0.22,
      height: 0.58,
      segments: 18,
    );
    final boltLanceGeo = VrSculptedGeometry.capsule(
      radius: 0.10,
      height: 0.58,
      capRings: 4,
      segments: 14,
    );

    fs.InstancedMesh makeBatch(
      fs.Geometry geo,
      fs.Material mat,
      void Function(fs.Node) assignNode,
    ) {
      final mesh = fs.InstancedMesh(
        geometry: geo,
        material: mat,
        cullInstances: true,
      );
      final node = fs.Node()
        ..raycastable = false
        ..addComponent(fs.InstancedMeshComponent(mesh));
      _scene.add(node);
      assignNode(node);
      return mesh;
    }

    _wallMat = fs.PhysicallyBasedMaterial()
      ..baseColorFactor = vm.Vector4(0.18, 0.22, 0.29, 1.0)
      ..metallicFactor = 0.78
      ..roughnessFactor = 0.46
      ..vertexColorWeight = 1.0;
    _wallBatch = makeBatch(groundedWallUnit, _wallMat!, (n) => _wallNode = n);

    _floorMat = fs.PhysicallyBasedMaterial()
      ..baseColorFactor = vm.Vector4(0.09, 0.12, 0.17, 1.0)
      ..metallicFactor = 0.72
      ..roughnessFactor = 0.52
      ..vertexColorWeight = 0.0;
    _floorBatch = makeBatch(beveledUnit, _floorMat!, (n) => _floorNode = n);

    _cpuBaseMat = fs.PhysicallyBasedMaterial()
      ..baseColorFactor = vm.Vector4(0.15, 0.19, 0.26, 1.0)
      ..metallicFactor = 0.85
      ..roughnessFactor = 0.34
      ..vertexColorWeight = 1.0;
    _cpuPedestalBatch = makeBatch(
      cpuPedestalGeo,
      _cpuBaseMat!,
      (n) => _cpuPedestalNode = n,
    );

    _cpuOfflineBatch = makeBatch(
      crystalGeo,
      fs.PhysicallyBasedMaterial()
        ..baseColorFactor = vm.Vector4(0.22, 0.52, 1.0, 1.0)
        ..emissiveFactor = vm.Vector4(0.18, 0.58, 1.05, 0.0)
        ..metallicFactor = 0.45
        ..roughnessFactor = 0.16
        ..vertexColorWeight = 0.0,
      (n) => _cpuOfflineNode = n,
    );

    _cpuOnlineBatch = makeBatch(
      crystalGeo,
      fs.PhysicallyBasedMaterial()
        ..baseColorFactor = vm.Vector4(0.12, 0.98, 0.56, 1.0)
        ..emissiveFactor = vm.Vector4(0.18, 1.05, 0.52, 0.0)
        ..metallicFactor = 0.45
        ..roughnessFactor = 0.14
        ..vertexColorWeight = 0.0,
      (n) => _cpuOnlineNode = n,
    );

    _spiderBatch = makeBatch(
      spiderCarapaceGeo,
      fs.PhysicallyBasedMaterial()
        ..baseColorFactor = vm.Vector4(0.95, 0.36, 0.12, 1.0)
        ..emissiveFactor = vm.Vector4(0.62, 0.16, 0.04, 0.0)
        ..metallicFactor = 0.70
        ..roughnessFactor = 0.28
        ..vertexColorWeight = 0.0,
      (n) => _spiderNode = n,
    );

    _spiderLegBatch = makeBatch(
      spiderLegsGeo,
      fs.PhysicallyBasedMaterial()
        ..baseColorFactor = vm.Vector4(0.24, 0.18, 0.16, 1.0)
        ..metallicFactor = 0.88
        ..roughnessFactor = 0.36
        ..vertexColorWeight = 0.0,
      (n) => _spiderLegNode = n,
    );

    _sentryBaseBatch = makeBatch(
      sentryBaseGeo,
      fs.PhysicallyBasedMaterial()
        ..baseColorFactor = vm.Vector4(0.20, 0.16, 0.20, 1.0)
        ..metallicFactor = 0.88
        ..roughnessFactor = 0.34
        ..vertexColorWeight = 1.0,
      (n) => _sentryBaseNode = n,
    );

    _sentryBatch = makeBatch(
      sentryHeadGeo,
      fs.PhysicallyBasedMaterial()
        ..baseColorFactor = vm.Vector4(0.92, 0.14, 0.22, 1.0)
        ..emissiveFactor = vm.Vector4(0.82, 0.08, 0.16, 0.0)
        ..metallicFactor = 0.85
        ..roughnessFactor = 0.22
        ..vertexColorWeight = 0.0,
      (n) => _sentryNode = n,
    );

    _medkitBatch = makeBatch(
      medkitPodGeo,
      fs.PhysicallyBasedMaterial()
        ..baseColorFactor = vm.Vector4(0.20, 1.0, 0.65, 1.0)
        ..emissiveFactor = vm.Vector4(0.28, 0.95, 0.58, 0.0)
        ..metallicFactor = 0.25
        ..roughnessFactor = 0.20
        ..vertexColorWeight = 0.0,
      (n) => _medkitNode = n,
    );

    _playerBoltBatch = makeBatch(
      boltLanceGeo,
      fs.PhysicallyBasedMaterial()
        ..baseColorFactor = vm.Vector4(1.0, 0.74, 0.24, 1.0)
        ..emissiveFactor = vm.Vector4(1.25, 0.72, 0.18, 0.0)
        ..roughnessFactor = 0.12
        ..vertexColorWeight = 0.0,
      (n) => _playerBoltNode = n,
    );

    _enemyBoltBatch = makeBatch(
      boltLanceGeo,
      fs.PhysicallyBasedMaterial()
        ..baseColorFactor = vm.Vector4(1.0, 0.16, 0.18, 1.0)
        ..emissiveFactor = vm.Vector4(1.25, 0.10, 0.14, 0.0)
        ..roughnessFactor = 0.12
        ..vertexColorWeight = 0.0,
      (n) => _enemyBoltNode = n,
    );

    final avatarBody = fs.Node(
      mesh: fs.Mesh(
        VrSculptedGeometry.capsule(radius: 0.32, height: 1.42, segments: 20),
        fs.PhysicallyBasedMaterial()
          ..baseColorFactor = vm.Vector4(0.10, 0.26, 0.38, 1.0)
          ..metallicFactor = 0.80
          ..roughnessFactor = 0.28
          ..vertexColorWeight = 0.0,
      ),
    );
    final avatarVisor = fs.Node(
      mesh: fs.Mesh(
        VrSculptedGeometry.beveledBox(
          vm.Vector3(0.46, 0.16, 0.28),
          cornerRadius: 0.06,
        ),
        fs.PhysicallyBasedMaterial()
          ..baseColorFactor = vm.Vector4(0.0, 0.94, 1.0, 1.0)
          ..emissiveFactor = vm.Vector4(0.0, 0.85, 1.15, 0.0)
          ..roughnessFactor = 0.15
          ..vertexColorWeight = 0.0,
      ),
    )..localTransform = vm.Matrix4.translationValues(0.0, 0.42, 0.20);

    _playerAvatarNode = fs.Node()
      ..raycastable = false
      ..visible = _tacticalChaseView
      ..add(avatarBody)
      ..add(avatarVisor);
    _scene.add(_playerAvatarNode!);
  }

  Future<void> _dressSectorMaterials() async {
    bool isCurrent() => mounted;
    final tier = widget.quality?.tier;
    await Future.wait([
      if (_wallMat != null)
        PbrTextureLibrary.apply(
          _wallMat!,
          const PbrTextureRequest(
            PbrSurface.sciFiTrimSheet,
            size: 512,
            seed: 301,
            primary: 0xFF6B7D96,
            secondary: 0xFFD97A2B,
            repeats: 2,
            reliefStrength: 1.0,
          ),
          isCurrent: isCurrent,
          tiles: vm.Vector2(1, 1),
          normalScale: 0.90,
          metallicFactor: 0.90,
          roughnessFactor: 0.95,
          qualityTier: tier,
          role: VrTextureRole.heroSurface,
        ),
      if (_floorMat != null)
        PbrTextureLibrary.apply(
          _floorMat!,
          const PbrTextureRequest(
            PbrSurface.sciFiGrating,
            size: 512,
            seed: 307,
            primary: 0xFF4A5A70,
            secondary: 0xFF101620,
            repeats: 2,
            reliefStrength: 1.0,
          ),
          isCurrent: isCurrent,
          tiles: vm.Vector2(1, 1),
          normalScale: 0.90,
          metallicFactor: 0.84,
          roughnessFactor: 0.95,
          qualityTier: tier,
          role: VrTextureRole.floor,
        ),
      if (_cpuBaseMat != null)
        PbrTextureLibrary.apply(
          _cpuBaseMat!,
          const PbrTextureRequest(
            PbrSurface.carbonHex,
            size: 256,
            seed: 311,
            primary: 0xFF52647C,
            secondary: 0xFF18202C,
            repeats: 2,
          ),
          isCurrent: isCurrent,
          tiles: vm.Vector2(2, 2),
          normalScale: 0.75,
          metallicFactor: 0.88,
          qualityTier: tier,
          role: VrTextureRole.prop,
        ),
    ]);
  }

  void _rebuildStaticSectorMeshes() {
    _builtSector = _game.sector;

    final walls = _wallBatch!;
    if (walls.instanceCount > 0) walls.clearInstances();
    for (final w in _game.walls) {
      final m = vm.Matrix4.translationValues(
        w.centerX,
        w.heightMeters * 0.5,
        w.centerZ,
      )..scaleByVector3(
        vm.Vector3(w.widthMeters, w.heightMeters, w.depthMeters),
      );
      walls.addInstance(m);
    }
    _wallNode?.visible = walls.instanceCount > 0;

    final floors = _floorBatch!;
    if (floors.instanceCount > 0) floors.clearInstances();
    const tile = Underrun3dGame.tileMeters;
    for (final (gx, gz) in _game.floorTiles) {
      final m = vm.Matrix4.translationValues(
        Underrun3dGame.cellCenter(gx),
        -0.04,
        Underrun3dGame.cellCenter(gz),
      )..scaleByVector3(vm.Vector3(tile * 0.98, 0.08, tile * 0.98));
      floors.addInstance(m);
    }
    _floorNode?.visible = floors.instanceCount > 0;
  }

  void _onInput(VrInputEvent event) {
    final map = event.data is Map ? event.data as Map : null;

    switch (event.type) {
      case VrInputType.navigate:
        if (!event.active || map == null) {
          _stickMoveX = 0.0;
          _stickMoveY = 0.0;
          _stickTurnX = 0.0;
          _stickTurnY = 0.0;
          return;
        }
        _stickMoveX = (map['stickX'] as num? ?? map['x'] as num? ?? 0.0)
            .toDouble();
        _stickMoveY = (map['stickY'] as num? ?? map['y'] as num? ?? 0.0)
            .toDouble();
        _stickTurnX =
            (map['lookX'] as num? ?? map['turnRate'] as num? ?? 0.0).toDouble();
        _stickTurnY =
            (map['lookY'] as num? ?? map['pitchRate'] as num? ?? 0.0)
                .toDouble();
      case VrInputType.select:
      case VrInputType.buttonR:
        if (event.active) {
          event.consume();
          if (_game.campaignCompleted) {
            _game.loadSector(1);
            _rebuildStaticSectorMeshes();
          } else {
            _fireBurstSeconds = 0.22;
          }
        }
      case VrInputType.grip:
      case VrInputType.buttonZR:
        _remoteFireHeld = event.active;
      case VrInputType.buttonX:
        if (event.active) {
          event.consume();
          setState(() {
            _tacticalChaseView = !_tacticalChaseView;
            if (!_tacticalChaseView) {
              _rig.bodyPitch = 0.0;
            }
            _playerAvatarNode?.visible = _tacticalChaseView;
          });
        }
      case VrInputType.buttonY:
      case VrInputType.recenter:
        if (event.active) {
          _rig.recenter();
        }
      case VrInputType.buttonL:
      case VrInputType.buttonZL:
        if (event.active) {
          event.consume();
          setState(() {
            _slowMo = !_slowMo;
          });
        }
      default:
        break;
    }
  }

  KeyEventResult _handleKeyEvent(FocusNode _, KeyEvent event) {
    final key = event.logicalKey;
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      _heldKeys.add(key);
      if (event is KeyDownEvent && key == LogicalKeyboardKey.keyV) {
        setState(() {
          _tacticalChaseView = !_tacticalChaseView;
          _playerAvatarNode?.visible = _tacticalChaseView;
        });
        return KeyEventResult.handled;
      }
      if (event is KeyDownEvent && key == LogicalKeyboardKey.escape) {
        _exit();
        return KeyEventResult.handled;
      }
    } else if (event is KeyUpEvent) {
      _heldKeys.remove(key);
    }
    if (_isGameKey(key)) return KeyEventResult.handled;
    return KeyEventResult.ignored;
  }

  static bool _isGameKey(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.keyW ||
      key == LogicalKeyboardKey.keyA ||
      key == LogicalKeyboardKey.keyS ||
      key == LogicalKeyboardKey.keyD ||
      key == LogicalKeyboardKey.arrowUp ||
      key == LogicalKeyboardKey.arrowDown ||
      key == LogicalKeyboardKey.arrowLeft ||
      key == LogicalKeyboardKey.arrowRight ||
      key == LogicalKeyboardKey.space;

  void _tick(Duration _, double dt) {
    // Combine keyboard + remote controller stick inputs.
    var rawRight = _stickMoveX;
    var rawForward = _stickMoveY;
    if (_heldKeys.contains(LogicalKeyboardKey.keyD) ||
        _heldKeys.contains(LogicalKeyboardKey.arrowRight)) {
      rawRight += 1.0;
    }
    if (_heldKeys.contains(LogicalKeyboardKey.keyA) ||
        _heldKeys.contains(LogicalKeyboardKey.arrowLeft)) {
      rawRight -= 1.0;
    }
    if (_heldKeys.contains(LogicalKeyboardKey.keyW) ||
        _heldKeys.contains(LogicalKeyboardKey.arrowUp)) {
      rawForward += 1.0;
    }
    if (_heldKeys.contains(LogicalKeyboardKey.keyS) ||
        _heldKeys.contains(LogicalKeyboardKey.arrowDown)) {
      rawForward -= 1.0;
    }

    double worldMoveX;
    double worldMoveZ;
    double? aimYaw;

    if (_tacticalChaseView) {
      // Top-down / isometric chase axes: +X right, -Z north.
      worldMoveX = rawRight.clamp(-1.0, 1.0);
      worldMoveZ = (-rawForward).clamp(-1.0, 1.0);
      if (_stickTurnX.abs() > 0.12 || _stickTurnY.abs() > 0.12) {
        aimYaw = math.atan2(_stickTurnX, -_stickTurnY);
      }
    } else {
      // First-person VR: project stick relative to horizontal head/body yaw!
      if (_stickTurnX.abs() > 0.02) {
        _rig.bodyYaw -= _stickTurnX * 2.4 * dt;
      }
      final fwd = _rig.forward;
      var fx = fwd.x;
      var fz = fwd.z;
      final flen = math.sqrt(fx * fx + fz * fz);
      if (flen > 1e-4) {
        fx /= flen;
        fz /= flen;
      } else {
        fx = 0.0;
        fz = -1.0;
      }
      // Right vector on XZ plane for `(fx, 0, fz)` with +Y up is `(-fz, 0, fx)`:
      final rx = -fz;
      final rz = fx;
      worldMoveX = (fx * rawForward + rx * rawRight).clamp(-1.0, 1.0);
      worldMoveZ = (fz * rawForward + rz * rawRight).clamp(-1.0, 1.0);
      aimYaw = math.atan2(fx, fz);
    }

    if (_fireBurstSeconds > 0) {
      _fireBurstSeconds = math.max(0.0, _fireBurstSeconds - dt);
    }
    final firing =
        _remoteFireHeld ||
        _fireBurstSeconds > 0 ||
        _touchFireHeld ||
        _heldKeys.contains(LogicalKeyboardKey.space);

    final effectiveDt = _slowMo ? dt * 0.55 : dt;
    _animClock = (_animClock + effectiveDt) % (math.pi * 40.0);
    _game.step(
      effectiveDt,
      UnderrunInputFrame(
        moveX: worldMoveX,
        moveZ: worldMoveZ,
        aimYawRadians: aimYaw,
        firePressed: firing,
      ),
    );

    if (_builtSector != _game.sector) {
      _rebuildStaticSectorMeshes();
    }

    // Update VR rig eye pose + camera shake.
    final eye = _game.playerEye;
    final shake = _game.cameraShake;
    final jx =
        shake > 0 ? math.sin(eye.x * 19.0 + dt * 97.0) * shake * 0.12 : 0.0;
    final jz =
        shake > 0 ? math.cos(eye.z * 17.0 + dt * 83.0) * shake * 0.12 : 0.0;

    if (_tacticalChaseView) {
      _rig.eyeCenter.setValues(eye.x + jx, 9.5, eye.z + 6.5 + jz);
      _rig.bodyPitch = -0.88 - _rig.cameraRig.pitch;
      _playerAvatarNode
        ?..visible = true
        ..localTransform = (vm.Matrix4.translationValues(eye.x, 0.76, eye.z)
          ..rotateY(_game.aimYawRadians));
    } else {
      _rig.eyeCenter.setValues(eye.x + jx, eye.y, eye.z + jz);
      _playerAvatarNode?.visible = false;
    }

    _torchNode?.localTransform = vm.Matrix4.translationValues(
      eye.x,
      2.15,
      eye.z,
    );

    _syncDynamicBatches();
    _hud.value = _HudSnapshot(
      sector: _game.sector,
      health: _game.playerHealth,
      cpusRebooted: _game.cpusRebooted,
      cpusTotal: _game.cpusTotal,
      kills: _game.kills,
      notice: _game.noticeRemainingSeconds > 0 ? _game.terminalNotice : '',
      completed: _game.campaignCompleted,
    );
  }

  void _syncDynamicBatches() {
    void resetBatch(fs.InstancedMesh mesh) {
      if (mesh.instanceCount > 0) mesh.clearInstances();
    }

    final cpuPedestals = _cpuPedestalBatch!;
    final cpuOff = _cpuOfflineBatch!;
    final cpuOn = _cpuOnlineBatch!;
    resetBatch(cpuPedestals);
    resetBatch(cpuOff);
    resetBatch(cpuOn);
    for (var i = 0; i < _game.cpus.length; i++) {
      final cpu = _game.cpus[i];
      cpuPedestals.addInstance(
        vm.Matrix4.translationValues(cpu.x, 0.62, cpu.z),
      );
      final phase = _animClock * (cpu.rebooted ? 2.4 : 1.1) + i * 0.85;
      final crystalY = 1.76 + 0.08 * math.sin(phase);
      final crystalM = vm.Matrix4.translationValues(cpu.x, crystalY, cpu.z)
        ..rotateY(phase);
      if (cpu.rebooted) {
        cpuOn.addInstance(crystalM);
      } else {
        cpuOff.addInstance(crystalM);
      }
    }
    _cpuPedestalNode?.visible = cpuPedestals.instanceCount > 0;
    _cpuOfflineNode?.visible = cpuOff.instanceCount > 0;
    _cpuOnlineNode?.visible = cpuOn.instanceCount > 0;

    final spiders = _spiderBatch!;
    final spiderLegs = _spiderLegBatch!;
    final sentryBases = _sentryBaseBatch!;
    final sentries = _sentryBatch!;
    resetBatch(spiders);
    resetBatch(spiderLegs);
    resetBatch(sentryBases);
    resetBatch(sentries);

    final playerX = _game.playerX;
    final playerZ = _game.playerZ;

    for (var i = 0; i < _game.enemies.length; i++) {
      final e = _game.enemies[i];
      if (!e.isAlive) continue;
      if (e.kind == UnderrunEnemyKind.spider) {
        final gait = _animClock * 9.5 + i * 1.3;
        final bobY = 0.44 + 0.045 * math.sin(gait).abs();
        final heading = (e.vx.abs() + e.vz.abs()) > 0.05
            ? math.atan2(e.vx, e.vz)
            : math.atan2(playerX - e.x, playerZ - e.z);
        spiders.addInstance(
          vm.Matrix4.translationValues(e.x, bobY, e.z)
            ..rotateY(heading)
            ..rotateZ(0.10 * math.sin(gait)),
        );
        // Crossed articulated X-legs (4 legs per spider in one shared batch!):
        spiderLegs
          ..addInstance(
            vm.Matrix4.translationValues(e.x, 0.24, e.z)
              ..rotateY(heading + math.pi * 0.25)
              ..rotateZ(0.14 * math.sin(gait)),
          )
          ..addInstance(
            vm.Matrix4.translationValues(e.x, 0.24, e.z)
              ..rotateY(heading - math.pi * 0.25)
              ..rotateZ(-0.14 * math.sin(gait)),
          );
      } else {
        sentryBases.addInstance(
          vm.Matrix4.translationValues(e.x, 0.56, e.z),
        );
        final turretYaw = math.atan2(playerX - e.x, playerZ - e.z);
        sentries.addInstance(
          vm.Matrix4.translationValues(e.x, 1.34, e.z)..rotateY(turretYaw),
        );
      }
    }
    _spiderNode?.visible = spiders.instanceCount > 0;
    _spiderLegNode?.visible = spiderLegs.instanceCount > 0;
    _sentryBaseNode?.visible = sentryBases.instanceCount > 0;
    _sentryNode?.visible = sentries.instanceCount > 0;

    final medkits = _medkitBatch!;
    resetBatch(medkits);
    for (var i = 0; i < _game.medkits.length; i++) {
      final med = _game.medkits[i];
      if (med.collected) continue;
      final phase = _animClock * 2.2 + i;
      medkits.addInstance(
        vm.Matrix4.translationValues(
          med.x,
          0.48 + 0.06 * math.sin(phase),
          med.z,
        )..rotateY(phase * 0.8),
      );
    }
    _medkitNode?.visible = medkits.instanceCount > 0;

    final pBolts = _playerBoltBatch!;
    final eBolts = _enemyBoltBatch!;
    resetBatch(pBolts);
    resetBatch(eBolts);
    for (final b in _game.bolts) {
      if (b.expired) continue;
      final boltYaw = math.atan2(b.vx, b.vz);
      final m = vm.Matrix4.translationValues(b.x, b.y, b.z)
        ..rotateY(boltYaw)
        ..rotateX(math.pi * 0.5)
        ..scaleByVector3(vm.Vector3.all(b.fromPlayer ? 0.92 : 1.08));
      if (b.fromPlayer) {
        pBolts.addInstance(m);
      } else {
        eBolts.addInstance(m);
      }
    }
    _playerBoltNode?.visible = pBolts.instanceCount > 0;
    _enemyBoltNode?.visible = eBolts.instanceCount > 0;
  }

  void _exit() {
    if (widget.onExit != null) {
      widget.onExit!();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _keyboardFocus,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            StereoSceneView(
              scene: _scene,
              rig: _rig,
              arbiter: _arbiter,
              locomotionEnabled: false,
              lookInputEnabled: false,
              enableHandTracking: false,
              showHomeControl: false,
              sgsrUpscale: widget.sgsrUpscale,
              quality: widget.quality,
              look: const VrLook(
                exposure: 1.05,
                saturation: 1.12,
                contrast: 1.08,
                bloomIntensity: 0.28,
                bloomThreshold: 0.85,
                vignetteIntensity: 0.16,
                ambientOcclusion: true,
              ),
              onUnhandledTempleTap: () {
                _touchFireHeld = true;
                Future<void>.delayed(const Duration(milliseconds: 120), () {
                  _touchFireHeld = false;
                });
              },
              onTick: _tick,
            ),
            Positioned(
              top: 10,
              left: 14,
              right: 14,
              child: SafeArea(
                bottom: false,
                child: ValueListenableBuilder<_HudSnapshot>(
                  valueListenable: _hud,
                  builder: (_, snap, _) => Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xCC0B131E),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0x6600E5FF)),
                        ),
                        child: Text(
                          'UNDERRUN 3D · SECTOR ${snap.sector}/3  |  '
                          'CPU ${snap.cpusRebooted}/${snap.cpusTotal}  |  '
                          'HP ${'▮' * snap.health}${'▯' * (5 - snap.health)}  |  '
                          'KILLS ${snap.kills}',
                          style: const TextStyle(
                            color: Color(0xFFE0F7FA),
                            fontSize: 11.5,
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const Spacer(),
                      IconButton.filledTonal(
                        tooltip: _tacticalChaseView
                            ? 'Vista 1ª Persona VR'
                            : 'Vista Táctica 3D',
                        onPressed: () {
                          setState(() {
                            _tacticalChaseView = !_tacticalChaseView;
                            _playerAvatarNode?.visible = _tacticalChaseView;
                          });
                        },
                        icon: Icon(
                          _tacticalChaseView
                              ? Icons.vrpano_rounded
                              : Icons.grid_view_rounded,
                          size: 18,
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filledTonal(
                        tooltip: 'Salir',
                        onPressed: _exit,
                        icon: const Icon(Icons.close_rounded, size: 18),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: 18,
              left: 24,
              right: 24,
              child: SafeArea(
                top: false,
                child: Row(
                  children: [
                    Expanded(
                      child: ValueListenableBuilder<_HudSnapshot>(
                        valueListenable: _hud,
                        builder: (_, snap, _) => snap.notice.isEmpty
                            ? const SizedBox.shrink()
                            : Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xD9091019),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: snap.completed
                                        ? const Color(0xFF00E676)
                                        : const Color(0x88FF9100),
                                  ),
                                ),
                                child: Text(
                                  snap.notice,
                                  style: const TextStyle(
                                    color: Color(0xFFFFD180),
                                    fontSize: 12,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Listener(
                      onPointerDown: (_) => _touchFireHeld = true,
                      onPointerUp: (_) => _touchFireHeld = false,
                      onPointerCancel: (_) => _touchFireHeld = false,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xCCFF6D00),
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: const Text(
                          'PLASMA',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.1,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

@immutable
class _HudSnapshot {
  const _HudSnapshot({
    required this.sector,
    required this.health,
    required this.cpusRebooted,
    required this.cpusTotal,
    required this.kills,
    required this.notice,
    required this.completed,
  });

  final int sector;
  final int health;
  final int cpusRebooted;
  final int cpusTotal;
  final int kills;
  final String notice;
  final bool completed;

  @override
  bool operator ==(Object other) =>
      other is _HudSnapshot &&
      other.sector == sector &&
      other.health == health &&
      other.cpusRebooted == cpusRebooted &&
      other.cpusTotal == cpusTotal &&
      other.kills == kills &&
      other.notice == notice &&
      other.completed == completed;

  @override
  int get hashCode => Object.hash(
    sector,
    health,
    cpusRebooted,
    cpusTotal,
    kills,
    notice,
    completed,
  );
}
