import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;
import 'package:vrlizate_scene/vrlizate_scene.dart';

import '../../vrlizate_apps.dart';
import 'vrlw_scene_adapter.dart';

/// SDK-owned interpreter for validated local-world data, never downloaded code.
/// A host supplies durable storage and may provide controller events through
/// VrInputSessionScope. The same renderer also accepts gaze and desktop keys.
class VrlzWorldViewer extends StatelessWidget {
  const VrlzWorldViewer({
    super.key,
    required this.bundle,
    required this.saveStore,
    this.onExit,
  });

  final VrlzWorldBundle bundle;
  final VrlzWorldPersistence saveStore;
  final VoidCallback? onExit;

  @override
  Widget build(BuildContext context) => VrGpuResourceGate(
    onBack: onExit,
    builder: (_) => _WorldPlayer(
      key: ObjectKey(bundle),
      bundle: bundle,
      saveStore: saveStore,
      onExit: onExit,
    ),
  );
}

class _WorldPlayer extends StatefulWidget {
  const _WorldPlayer({
    super.key,
    required this.bundle,
    required this.saveStore,
    this.onExit,
  });
  final VrlzWorldBundle bundle;
  final VrlzWorldPersistence saveStore;
  final VoidCallback? onExit;
  @override
  State<_WorldPlayer> createState() => _WorldPlayerState();
}

class _WorldPlayerState extends State<_WorldPlayer>
    with WidgetsBindingObserver {
  final _rig = StereoHeadRig(eyeCenter: vm.Vector3(0, 1.6, 0));
  late final VrlzWorldSession _session = VrlzWorldSession(widget.bundle);
  VrlzPreparedWorld? _prepared;
  VrlwSceneAdapter? _adapter;
  VrInputArbiter? _arbiter;
  Timer? _autosave;
  Object? _error;
  String? _saveError;
  String? _lastSnapshot;
  int _generation = 0;
  bool _loading = true, _exiting = false, _canPop = false, _active = true;
  bool _portalsArmed = true, _sessionReady = false, _routeTicking = true;
  final _lastValidPosition = vm.Vector3.zero();
  vm.Vector3? _arrivalForward;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_restoreAndOpen());
    _autosave = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_active && !_loading && _error == null && !_exiting) {
        unawaited(_save());
      }
    });
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
    _routeTicking = TickerMode.valuesOf(context).enabled;
    _active =
        _routeTicking &&
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.paused &&
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.hidden;
  }

  void _onInput(VrInputEvent event) {
    if (!event.handled && event.active && event.type == VrInputType.back) {
      event.consume();
      unawaited(_exit());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active =
        _routeTicking &&
        (state == AppLifecycleState.resumed ||
            state == AppLifecycleState.inactive);
    if (!_active && !_loading) unawaited(_save());
  }

  Future<void> _restoreAndOpen() async {
    try {
      final saved = await widget.saveStore.read(widget.bundle.manifest.id);
      if (!mounted) return;
      if (saved != null && _session.restoreSnapshot(saved)) {
        _portalsArmed = false;
      }
      _sessionReady = true;
      await _openWorld();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error;
          _loading = false;
        });
      }
    }
  }

  void _capturePose() {
    if (_loading || _adapter == null) return;
    final p = _rig.eyeCenter;
    // Keep persisted heading bounded even after many full turns.
    final yaw = math.atan2(math.sin(_rig.yaw), math.cos(_rig.yaw));
    _session.updatePose(VrlzWorldPose(x: p.x, y: p.y, z: p.z, yaw: yaw));
  }

  Future<bool> _save({bool capture = true}) async {
    if (!_sessionReady) return true;
    try {
      if (capture) _capturePose();
      final pose = _session.pose;
      final stamp =
          '${_session.currentWorld}:${pose.x}:${pose.y}:${pose.z}:${pose.yaw}';
      if (stamp == _lastSnapshot) return true;
      final bytes = _session.encodeSnapshot();
      await widget.saveStore.write(widget.bundle.manifest.id, bytes);
      _lastSnapshot = stamp;
      if (mounted && _saveError != null) setState(() => _saveError = null);
      return true;
    } catch (error) {
      if (mounted) setState(() => _saveError = 'No se pudo guardar: $error');
      return false;
    }
  }

  Future<void> _openWorld() async {
    final generation = ++_generation;
    bool current() => mounted && generation == _generation;
    _adapter?.dispose();
    _adapter = null;
    final previous = _prepared;
    _prepared = null;
    await previous?.reader.close();
    VrlzPreparedWorld? prepared;
    VrlwSceneAdapter? adapter;
    try {
      prepared = await widget.bundle.openWorld(_session.currentWorld);
      if (!current()) {
        await prepared.reader.close();
        return;
      }
      adapter = await VrlwSceneAdapter.create(
        prepared.reader,
        prepared.resources,
        isCurrent: current,
      );
      if (!current()) {
        adapter.dispose();
        await prepared.reader.close();
        return;
      }
      final portals = widget.bundle.manifest.portals.where(
        (p) => p.from == _session.currentWorld,
      );
      for (final portal in portals) {
        await _addPortal(adapter.scene, portal, current);
        if (!current()) {
          adapter.dispose();
          await prepared.reader.close();
          return;
        }
      }
      final pose = _session.pose;
      _rig.eyeCenter.setValues(pose.x, pose.y, pose.z);
      _lastValidPosition.setFrom(_rig.eyeCenter);
      _rig.bodyYaw = pose.yaw - _rig.cameraRig.yaw;
      _rig.bodyPitch = 0;
      _arrivalForward = _portalsArmed ? null : _rig.forward.clone();
      adapter.update(_rig.eyeCenter, 0);
      adapter.scene.onError = (error) => _failAfterFrame(error, generation);
      setState(() {
        _prepared = prepared;
        _adapter = adapter;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      adapter?.dispose();
      await prepared?.reader.close();
      if (current()) {
        setState(() {
          _loading = false;
          _error = error;
        });
      }
    }
  }

  static Future<void> _addPortal(
    fs.Scene scene,
    VrlzWorldPortal portal,
    bool Function() current,
  ) async {
    final center = vm.Vector3.array(portal.position);
    final material = fs.PhysicallyBasedMaterial()
      ..baseColorFactor = vm.Vector4(.025, .18, .2, 1)
      ..emissiveFactor = vm.Vector4(.08, .35, .4, 0)
      ..metallicFactor = .1
      ..roughnessFactor = .8
      ..vertexColorWeight = 0;
    scene.add(
      fs.Node(
          name: 'vrlz_portal_${portal.id}',
          mesh: fs.Mesh(fs.CuboidGeometry(vm.Vector3(2.6, 2.8, .12)), material),
        )
        ..position = center
        ..shadowCastingMode = fs.ShadowCastingMode.off,
    );
    for (final line in [
      (portal.label, .45, .23),
      ('MIRA PARA VIAJAR · A', -.45, .14),
    ]) {
      final label = await VrTextLabel.create(
        line.$1,
        center: center + vm.Vector3(0, line.$2, .08),
        height: line.$3,
        color: const Color(0xffe8fcff),
        fontSize: 64,
        maxWidthPx: 2048,
        maxLines: 2,
      );
      if (!current()) return;
      final scale = math.min(1.0, 2.2 / label.worldWidth);
      label.node.localTransform.scaleByDouble(scale, scale, scale, 1);
      scene.add(label.node..shadowCastingMode = fs.ShadowCastingMode.off);
    }
  }

  VrlzWorldPortal? _portalFor(fs.Node node) {
    for (final portal in widget.bundle.manifest.portals) {
      if (portal.from == _session.currentWorld &&
          node.name == 'vrlz_portal_${portal.id}') {
        return portal;
      }
    }
    return null;
  }

  bool _canSelect(fs.Node node) {
    final portal = _portalFor(node);
    return portal == null ||
        (!_loading &&
            !_exiting &&
            _portalsArmed &&
            vm.Vector3.array(portal.position).distanceTo(_rig.eyeCenter) <=
                4.5);
  }

  Future<void> _travel(fs.Node node) async {
    final portal = _portalFor(node);
    if (portal == null || !_canSelect(node)) return;
    _capturePose();
    if (!_session.enterPortal(portal.id)) return;
    setState(() {
      _loading = true;
      _portalsArmed = false;
    });
    await _save(capture: false);
    if (mounted) await _openWorld();
  }

  void _failAfterFrame(Object error, int generation) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && generation == _generation && _error == null) {
        setState(() => _error = error);
      }
    });
  }

  void _tick(Duration _, double dt) {
    if (_loading || _exiting || _error != null) return;
    try {
      // Keyboard fallback for creator testing. VR controllers use the shared
      // SDK arbiter and StereoSceneView's locomotion policy.
      final keys = _arbiter == null
          ? HardwareKeyboard.instance.logicalKeysPressed
          : const <LogicalKeyboardKey>{};
      final step = dt.clamp(0.0, .05);
      final forward = _rig.forward..y = 0;
      if (forward.length2 > .001) forward.normalize();
      final right = _rig.screenRight..y = 0;
      if (right.length2 > .001) right.normalize();
      var x = 0.0, z = 0.0;
      if (keys.contains(LogicalKeyboardKey.keyW)) z++;
      if (keys.contains(LogicalKeyboardKey.keyS)) z--;
      if (keys.contains(LogicalKeyboardKey.keyD)) x++;
      if (keys.contains(LogicalKeyboardKey.keyA)) x--;
      final norm = math.max(1.0, math.sqrt(x * x + z * z));
      _rig.eyeCenter.add((forward * z + right * x) * (2.5 * step / norm));
      if (keys.contains(LogicalKeyboardKey.arrowLeft)) _rig.bodyYaw += step;
      if (keys.contains(LogicalKeyboardKey.arrowRight)) _rig.bodyYaw -= step;
      if (keys.contains(LogicalKeyboardKey.arrowUp)) _rig.bodyPitch -= step;
      if (keys.contains(LogicalKeyboardKey.arrowDown)) _rig.bodyPitch += step;
      // Stay inside authored cells so a saved pose always has a valid region.
      final index = _prepared!.reader.index;
      final eye = _rig.eyeCenter;
      if (!eye.x.isFinite ||
          !eye.y.isFinite ||
          !eye.z.isFinite ||
          eye.y.abs() > 1000000 ||
          index.chunkAt(
                (eye.x / index.cellSizeMeters).floor(),
                (eye.z / index.cellSizeMeters).floor(),
              ) ==
              null) {
        eye.setFrom(_lastValidPosition);
      } else {
        _lastValidPosition.setFrom(eye);
      }
      if (!_portalsArmed &&
          _arrivalForward != null &&
          _arrivalForward!.dot(_rig.forward) < .994521895) {
        _portalsArmed = true;
      }
      _adapter?.update(_rig.eyeCenter, dt);
    } catch (error) {
      _failAfterFrame(error, _generation);
    }
  }

  Future<void> _exit() async {
    if (_exiting) return;
    _exiting = true;
    if (!await _save()) {
      _exiting = false;
      return;
    }
    if (!mounted) return;
    setState(() => _canPop = true);
    // PopScope must rebuild before a normal Navigator pop is permitted.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.onExit != null) {
        widget.onExit!();
      } else {
        Navigator.of(context).maybePop();
      }
      _exiting = false;
    });
  }

  @override
  void dispose() {
    _capturePose();
    unawaited(_save(capture: false));
    _generation++;
    _autosave?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _arbiter?.removeListener(_onInput);
    _adapter?.dispose();
    unawaited(_prepared?.reader.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _canPop,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_exit());
    },
    child: VrWorldNavigationScope(
      onHome: () => unawaited(_exit()),
      child: Focus(
        autofocus: true,
        onKeyEvent: (_, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape) {
            unawaited(_exit());
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Scaffold(
          backgroundColor: const Color(0xff111923),
          body: Stack(
            fit: StackFit.expand,
            children: [
              if (!_loading && _error == null && _adapter != null)
                StereoSceneView(
                  key: ValueKey(_generation),
                  scene: _adapter!.scene,
                  rig: _rig,
                  look: const VrLook(bloomIntensity: 0),
                  enableHandTracking: false,
                  onTick: _tick,
                  gazeFilter: _canSelect,
                  onGazeSelect: (node) => unawaited(_travel(node)),
                ),
              if (_loading) const Center(child: CircularProgressIndicator()),
              if (_error != null)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'No se pudo abrir este mundo.\n$_error',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white),
                        ),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: () => unawaited(_exit()),
                          child: const Text('Volver'),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_saveError != null)
                Positioned(
                  bottom: 16,
                  left: 16,
                  right: 16,
                  child: Material(
                    color: const Color(0xff512c26),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        _saveError!,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
