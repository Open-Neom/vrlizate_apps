import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;
import 'package:vrlizate_scene/vrlizate_scene.dart';

import '../../vrlizate_apps.dart';
import '../../vrlizate_apps_expedition.dart';
import 'vrlw_scene_adapter.dart';
import 'vrlw_world_activity.dart';
import 'vrlw_world_audio.dart';
import 'vrlz_expedition_presenter.dart';
import 'vrlz_expedition_scene_ui.dart';
import 'vrlz_viewer_save_barrier.dart';
import 'vrlz_expedition_actor.dart';
import 'vrlz_expedition_occlusion.dart';
import 'vrlz_expedition_task.dart';
import 'vrlz_world_change_policy.dart';
import 'vrlz_world_change_overlay.dart';

/// SDK-owned interpreter for validated local-world data, never downloaded code.
/// A host supplies durable storage and may provide controller events through
/// VrInputSessionScope. The same renderer also accepts gaze and desktop keys.
class VrlzWorldViewer extends StatelessWidget {
  const VrlzWorldViewer({
    super.key,
    required this.bundle,
    required this.saveStore,
    this.initialWorld,
    this.onExit,
    this.audioOutputFactory,
    this.expedition,
  });

  final VrlzWorldBundle bundle;
  final VrlzWorldPersistence saveStore;

  /// Optional explicit, declared destination chosen by the host. The saved
  /// visits are restored first, then this world's last pose (or authored spawn)
  /// is selected. Null resumes the saved current world as before.
  final String? initialWorld;
  final VoidCallback? onExit;
  final VrlwAudioOutput Function()? audioOutputFactory;

  /// Optional campaign already restored by its host, which owns its disposal.
  /// The viewer never reads campaign storage or creates another controller.
  final VrlzExpeditionController? expedition;

  @override
  Widget build(BuildContext context) => VrGpuResourceGate(
    onBack: onExit,
    builder: (_) => _WorldPlayer(
      key: ValueKey((bundle, initialWorld, expedition)),
      bundle: bundle,
      saveStore: saveStore,
      initialWorld: initialWorld,
      onExit: onExit,
      audioOutputFactory: audioOutputFactory,
      expedition: expedition,
    ),
  );
}

class _WorldPlayer extends StatefulWidget {
  const _WorldPlayer({
    super.key,
    required this.bundle,
    required this.saveStore,
    this.initialWorld,
    this.onExit,
    this.audioOutputFactory,
    this.expedition,
  });
  final VrlzWorldBundle bundle;
  final VrlzWorldPersistence saveStore;
  final String? initialWorld;
  final VoidCallback? onExit;
  final VrlwAudioOutput Function()? audioOutputFactory;
  final VrlzExpeditionController? expedition;
  @override
  State<_WorldPlayer> createState() => _WorldPlayerState();
}

class _WorldPlayerState extends State<_WorldPlayer>
    with WidgetsBindingObserver {
  final _rig = StereoHeadRig(eyeCenter: vm.Vector3(0, 1.6, 0));
  late final VrlzWorldSession _session = VrlzWorldSession(widget.bundle);
  VrlzPreparedWorld? _prepared;
  VrlwSceneAdapter? _adapter;
  VrlwWorldAudio? _audio;
  final _activities = <String, VrlwWorldActivity>{};
  final _indicators = <String, fs.PhysicallyBasedMaterial>{};
  VrlwWorldActivity? get _activity => _adapter?.activity;
  VrInputArbiter? _arbiter;
  Timer? _autosave;
  Object? _error;
  String? _saveError;
  String? _lastSnapshot;
  int _generation = 0;
  int _navigationEpoch = 0;
  bool _loading = true, _exiting = false, _canPop = false, _active = true;
  bool _portalsArmed = true, _sessionReady = false, _routeTicking = true;
  final _lastValidPosition = vm.Vector3.zero();
  vm.Vector3? _arrivalForward;
  final _passportInput = VrlzPassportInputPolicy();
  final _passportFocus = VrlzPassportFocus();
  final _passportButtons = <String, VrButton3D>{};
  fs.Node? _passportRoot, _objectiveRoot, _totemRoot, _sideRouteRoot;
  vm.Vector3? _totemPosition;
  int _passportEpoch = 0, _objectiveEpoch = 0, _passportPage = 0;
  bool _passportOpen = false;
  bool _passportBuilding = false, _passportQueued = false;
  vm.Vector3? _passportEye, _passportForward;
  String? _expeditionStamp;
  VrlzExpeditionActor? _questActor;
  final _questOcclusion = VrlzExpeditionOcclusion();
  bool _giverDialogue = false;
  String? _dialogueMissionId;
  final _passportActions = <String, VrlzPassportAction>{};
  List<VrlzPassportPage> _passportPrefix = const [];
  String? _inspectionChangeId;
  final _worldChangeBuild = VrlzWorldChangeBuildState();
  VrlzWorldChangeOverlay? _worldChangeOverlay;
  VrlzExpeditionTask? get _task => widget.expedition == null
      ? null
      : VrlzExpeditionTask.current(widget.expedition!);
  bool get _currentGiverDialogue =>
      _giverDialogue && _dialogueMissionId == _task?.actorId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.expedition?.addListener(_onExpeditionChanged);
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
    _routeTicking =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _active =
        _routeTicking &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed);
    _audio?.setActive(_active && !_loading && !_exiting && _error == null);
    if (!_active) {
      _passportInput.reset(requireNeutral: true);
      _clearPassportFocus();
      _clearWorldChange();
    } else {
      _refreshWorldChange();
    }
  }

  void _onInput(VrInputEvent event) {
    final intent = _passportInput.handle(
      event,
      active: _active,
      loading: _loading,
      exiting: _exiting,
      ready: widget.expedition?.ready ?? false,
      open: _passportOpen,
      hasFocus: _passportFocus.focused != null,
    );
    // StereoSceneView records axes in its early system listener; its explicit
    // motion gates below still own movement/look suppression while reading.
    if (_passportOpen && event.type == VrInputType.navigate) event.consume();
    switch (intent) {
      case VrlzPassportIntent.none:
        return;
      case VrlzPassportIntent.open:
        event.consume();
        _openPassport();
      case VrlzPassportIntent.close:
        event.consume();
        _closePassport();
      case VrlzPassportIntent.exit:
        event.consume();
        unawaited(_exit());
      case VrlzPassportIntent.previousPage:
      case VrlzPassportIntent.nextPage:
        event.consume();
        _passportAction(
          intent == VrlzPassportIntent.nextPage
              ? VrlzExpeditionSceneUi.nextName
              : VrlzExpeditionSceneUi.previousName,
        );
      case VrlzPassportIntent.previousControl:
      case VrlzPassportIntent.nextControl:
        event.consume();
        _passportFocus.move(intent == VrlzPassportIntent.nextControl ? 1 : -1);
        _paintPassportFocus();
      case VrlzPassportIntent.activateFocused:
        event.consume();
        final name = _passportFocus.focused;
        if (name != null && _canSelectPassport(name)) _passportAction(name);
      case VrlzPassportIntent.clearFocus:
        _clearPassportFocus();
    }
  }

  void _clearPassportFocus() {
    _passportFocus.clear();
    _paintPassportFocus();
  }

  void _paintPassportFocus() {
    for (final entry in _passportButtons.entries) {
      entry.value.debugMaterial.baseColorFactor =
          entry.key == _passportFocus.focused
          ? vm.Vector4(.12, .68, .72, 1)
          : entry.value.color;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = _routeTicking && state == AppLifecycleState.resumed;
    _audio?.setActive(_active && !_loading && !_exiting && _error == null);
    if (!_active) {
      _passportInput.reset(requireNeutral: true);
      _clearPassportFocus();
      _clearWorldChange();
    } else {
      _refreshWorldChange();
    }
    if (!_active && !_loading) unawaited(_save());
  }

  Future<void> _restoreAndOpen() async {
    try {
      final expedition = widget.expedition;
      if (expedition != null &&
          (!expedition.ready ||
              expedition.definition.experienceId != widget.bundle.manifest.id ||
              expedition.definition.worlds.keys.any(
                (alias) => !widget.bundle.manifest.worlds.any(
                  (world) => world.alias == alias,
                ),
              ))) {
        throw const FormatException(
          'La expedición no está preparada para esta experiencia.',
        );
      }
      final saved = await widget.saveStore.read(widget.bundle.manifest.id);
      if (!mounted) return;
      if (saved != null && _session.restoreSnapshot(saved)) {
        _portalsArmed = false;
      }
      final destination = widget.initialWorld;
      if (destination != null) {
        if (!_session.selectWorld(destination)) {
          throw FormatException(
            'Unknown declared world destination: $destination',
          );
        }
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
      final saved = await VrlzViewerSaveBarrier.save(
        writePose: () async {
          // Capture/validation/encoding can fail before a file write. Keep all
          // of them inside the barrier so discoveries still drain on failure.
          if (capture) _capturePose();
          final pose = _session.pose;
          final stamp =
              '${_session.currentWorld}:${pose.x}:${pose.y}:${pose.z}:${pose.yaw}';
          if (stamp == _lastSnapshot) return;
          final bytes = _session.encodeSnapshot();
          await widget.saveStore.write(widget.bundle.manifest.id, bytes);
          _lastSnapshot = stamp;
        },
        flushExpedition: widget.expedition?.flush,
      );
      if (saved.poseError != null) throw saved.poseError!;
      if (!saved.saved) {
        if (mounted) {
          setState(
            () => _saveError =
                widget.expedition?.saveError ??
                'No se pudo guardar el pasaporte.',
          );
        }
        return false;
      }
      if (mounted && _saveError != null) setState(() => _saveError = null);
      return true;
    } catch (error) {
      if (mounted) setState(() => _saveError = 'No se pudo guardar: $error');
      return false;
    }
  }

  Future<void> _openWorld() async {
    final generation = ++_generation;
    _removeExpeditionUi();
    bool current() => mounted && generation == _generation;
    final previousAudio = _audio;
    _audio = null;
    previousAudio?.setActive(false);
    await previousAudio?.dispose();
    if (!current()) return;
    _indicators.clear();
    _adapter?.dispose();
    _adapter = null;
    final previous = _prepared;
    _prepared = null;
    await previous?.reader.close();
    VrlzPreparedWorld? prepared;
    VrlwSceneAdapter? adapter;
    VrlwWorldAudio? audio;
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
        activity: _activities.putIfAbsent(
          prepared.reader.index.id,
          () => VrlwWorldActivity(prepared!.reader.index),
        ),
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
      await _addInteractions(adapter, current);
      if (!current()) {
        adapter.dispose();
        await prepared.reader.close();
        return;
      }
      if (widget.expedition != null) {
        final spawn = widget.bundle.manifest.world(_session.currentWorld).spawn;
        _totemPosition = vm.Vector3(spawn[0] + 1.1, 1.05, spawn[2] + 1.0);
        final totem = await VrlzExpeditionSceneUi.totem(
          _totemPosition!,
          eye: vm.Vector3.array(spawn),
          isCurrent: current,
        );
        if (!current()) {
          adapter.dispose();
          await prepared.reader.close();
          return;
        }
        if (totem != null) {
          _totemRoot = totem;
          adapter.scene.add(totem);
        }
      }
      final factory = widget.audioOutputFactory;
      if (factory != null && prepared.reader.index.audioEmitters.isNotEmpty) {
        audio = VrlwWorldAudio(
          output: factory(),
          emitters: prepared.reader.index.audioEmitters,
          resources: prepared.resources,
        );
        audio.setActive(false);
        await audio.initialize();
        if (!current()) {
          await audio.dispose();
          adapter.dispose();
          await prepared.reader.close();
          return;
        }
        for (final emitter in prepared.reader.index.audioEmitters) {
          audio.setEmitterEnabled(
            emitter.id,
            adapter.activity.audioEnabled(emitter.id),
          );
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
        _audio = audio;
        _loading = false;
        _error = null;
      });
      audio?.setActive(_active);
      widget.expedition?.visit(_session.currentWorld);
      _onExpeditionChanged();
    } catch (error) {
      await audio?.dispose();
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

  Future<void> _addInteractions(
    VrlwSceneAdapter adapter,
    bool Function() current,
  ) async {
    for (final item in adapter.reader.index.interactions) {
      final material = fs.PhysicallyBasedMaterial()
        ..metallicFactor = .15
        ..roughnessFactor = .8
        ..vertexColorWeight = 0;
      _indicators[item.id] = material;
      _setIndicator(material, adapter.activity.indicatorEnabled(item));
      final position = vm.Vector3.array(item.position);
      adapter.scene.add(
        fs.Node(
            name: 'vrlw_action_${item.id}',
            mesh: fs.Mesh(
              fs.CuboidGeometry(vm.Vector3(.42, .24, .16)),
              material,
            ),
          )
          ..position = position
          ..shadowCastingMode = fs.ShadowCastingMode.off,
      );
      final label = await VrTextLabel.create(
        '${item.label} · A',
        center: position + vm.Vector3(0, .30, .1),
        height: .14,
        color: const Color(0xffe8fcff),
        fontSize: 48,
        maxWidthPx: 768,
        maxLines: 2,
      );
      if (!current()) return;
      final scale = math.min(1.0, 1.2 / label.worldWidth);
      label.node.localTransform.scaleByDouble(scale, scale, scale, 1);
      adapter.scene.add(
        label.node
          ..raycastable = false
          ..shadowCastingMode = fs.ShadowCastingMode.off,
      );
    }
  }

  static void _setIndicator(fs.PhysicallyBasedMaterial material, bool enabled) {
    material.baseColorFactor = enabled
        ? vm.Vector4(.06, .56, .4, 1)
        : vm.Vector4(.22, .25, .28, 1);
    material.emissiveFactor = enabled
        ? vm.Vector4(.02, .15, .09, 0)
        : vm.Vector4.zero();
  }

  String? _actionId(fs.Node node) => node.name.startsWith('vrlw_action_')
      ? node.name.substring('vrlw_action_'.length)
      : null;

  void _onExpeditionChanged({bool force = false}) {
    final expedition = widget.expedition;
    if (!mounted ||
        expedition == null ||
        _loading ||
        _exiting ||
        _adapter == null) {
      return;
    }
    _refreshWorldChange();
    final stamp = VrlzPassportPresentation.stamp(expedition);
    if (!force && stamp == _expeditionStamp) return;
    _expeditionStamp = stamp;
    unawaited(_rebuildObjective());
    if (_passportOpen) unawaited(_rebuildPassport());
  }

  void _clearWorldChange() {
    _worldChangeBuild.invalidate();
    _worldChangeOverlay?.dispose();
    _worldChangeOverlay = null;
  }

  void _refreshWorldChange() {
    final adapter = _adapter, expedition = widget.expedition;
    if (!mounted ||
        !_active ||
        _loading ||
        _exiting ||
        _error != null ||
        adapter == null ||
        expedition == null) {
      return;
    }
    final change = expedition.worldChange(_session.currentWorld);
    if (_worldChangeBuild.id == change?.id) {
      _worldChangeOverlay?.setReactionVisible(
        !(_task?.showGiver(_session.currentWorld) ?? false),
      );
      return;
    }
    _clearWorldChange();
    if (_inspectionChangeId != null && _inspectionChangeId != change?.id) {
      _closePassport();
    }
    if (change == null) return;
    final epoch = _worldChangeBuild.begin(change.id);
    bool current() =>
        mounted &&
        _active &&
        !_loading &&
        !_exiting &&
        _error == null &&
        _worldChangeBuild.matches(epoch, change.id) &&
        identical(adapter, _adapter) &&
        widget.expedition?.worldChange(_session.currentWorld)?.id == change.id;
    unawaited(() async {
      try {
        final overlay = await VrlzWorldChangeOverlay.create(
          change,
          eye: _rig.eyeCenter,
          isCurrent: current,
        );
        if (!current() || overlay == null) {
          overlay?.dispose();
          if (_worldChangeBuild.discard(epoch)) _refreshWorldChange();
          return;
        }
        overlay.setReactionVisible(
          !(_task?.showGiver(_session.currentWorld) ?? false),
        );
        _worldChangeOverlay = overlay;
        adapter.scene.add(overlay.root);
      } catch (_) {
        final report = current();
        final discarded = _worldChangeBuild.discard(epoch);
        if (report) {
          setState(
            () => _saveError =
                'No se pudo mostrar la intervención. El historial sigue disponible con X.',
          );
        } else if (discarded) {
          _refreshWorldChange();
        }
      }
    }());
  }

  Future<void> _rebuildObjective() async {
    final epoch = ++_objectiveEpoch;
    final adapter = _adapter, expedition = widget.expedition;
    _questActor?.dispose();
    _questActor = null;
    _objectiveRoot?.detach();
    _sideRouteRoot?.detach();
    _objectiveRoot = _sideRouteRoot = null;
    if (adapter == null || expedition == null) return;
    final task = VrlzExpeditionTask.current(expedition);
    bool current() =>
        mounted &&
        epoch == _objectiveEpoch &&
        identical(adapter, _adapter) &&
        !_loading &&
        !_exiting;
    try {
      final route = VrlzExpeditionRoute.current(
        expedition,
        _session.currentWorld,
      );
      if (route != null) {
        final node = await VrlzExpeditionSceneUi.route(
          route,
          expedition.definition.worlds[route.destination]!,
          eye: _rig.eyeCenter,
          isCurrent: current,
        );
        if (!current()) return;
        if (node != null) {
          _sideRouteRoot = node;
          adapter.scene.add(node);
        }
      }
      if (!task.exists) return;
      final showGiver = task.showGiver(_session.currentWorld);
      final showObject = task.showObject(_session.currentWorld);
      if (task.giver != null && (showGiver || showObject)) {
        final actor = await VrlzExpeditionActor.createEntities(
          id: task.actorId!,
          giver: task.giver!,
          object: task.object,
          showGiver: showGiver,
          showObject: showObject,
          accepted: task.accepted,
          collected: task.collected,
          eye: _rig.eyeCenter,
          isCurrent: current,
        );
        if (!current() || actor == null) {
          actor?.dispose();
          return;
        }
        _questActor = actor;
        _objectiveRoot = actor.root;
        adapter.scene.add(actor.root);
      } else if (!task.isSide && task.mission?.world == _session.currentWorld) {
        final node = await VrlzExpeditionSceneUi.objective(
          task.mission!,
          eye: _rig.eyeCenter,
          isCurrent: current,
        );
        if (!current() || node == null) return;
        adapter.scene.add(node);
        _objectiveRoot = node;
      }
    } catch (_) {
      if (current()) {
        setState(
          () => _saveError =
              'No se pudo mostrar el objetivo. El pasaporte sigue disponible con X.',
        );
      }
    }
  }

  void _openPassport({
    String? discoveryMissionId,
    String? sideQuestId,
    bool giverDialogue = false,
    String? inspectionTitle,
    String? inspectionBody,
    String? inspectionChangeId,
  }) {
    if (!_active ||
        _loading ||
        _exiting ||
        _error != null ||
        !(widget.expedition?.ready ?? false) ||
        _adapter == null) {
      return;
    }
    if (_passportOpen) return;
    _passportPrefix = inspectionTitle != null && inspectionBody != null
        ? VrlzPassportPresentation.inspection(inspectionTitle, inspectionBody)
        : const [];
    _inspectionChangeId = inspectionChangeId;
    _giverDialogue = giverDialogue;
    _dialogueMissionId = giverDialogue ? _task?.actorId : null;
    _passportEye = _rig.eyeCenter.clone();
    _passportForward = _rig.forward;
    final presentation = VrlzPassportPresentation(
      widget.expedition!,
      dialogue: _currentGiverDialogue,
      prefixPages: _passportPrefix,
    );
    _passportPage = sideQuestId != null
        ? presentation.sideQuestPage(sideQuestId)
        : discoveryMissionId != null
        ? presentation.discoveryPage(discoveryMissionId)
        : 0;
    if (_passportPage < 0) _passportPage = 0;
    setState(() => _passportOpen = true);
    unawaited(_rebuildPassport());
  }

  void _closePassport() {
    if (!_passportOpen) return;
    _passportEpoch++;
    _passportQueued = false;
    _passportRoot?.parent?.remove(_passportRoot!);
    _passportRoot = null;
    _passportEye = null;
    _passportForward = null;
    _giverDialogue = false;
    _dialogueMissionId = null;
    _passportActions.clear();
    _passportFocus.replace(const []);
    _passportButtons.clear();
    _passportPrefix = const [];
    _inspectionChangeId = null;
    setState(() => _passportOpen = false);
  }

  Future<void> _rebuildPassport() async {
    final epoch = ++_passportEpoch;
    if (_passportBuilding) {
      _passportQueued = true;
      return;
    }
    final adapter = _adapter, expedition = widget.expedition;
    if (!_passportOpen || adapter == null || expedition == null) return;
    _passportBuilding = true;
    _passportActions.clear();
    _passportFocus.replace(const []);
    _paintPassportFocus();
    final presentation = VrlzPassportPresentation(
      expedition,
      dialogue: _currentGiverDialogue,
      prefixPages: _passportPrefix,
    );
    _passportPage = _passportPage.clamp(0, presentation.pages.length - 1);
    bool current() =>
        mounted &&
        epoch == _passportEpoch &&
        _passportOpen &&
        identical(adapter, _adapter) &&
        !_loading &&
        !_exiting;
    try {
      final buttons = <String, VrButton3D>{};
      final node = await VrlzExpeditionSceneUi.passport(
        presentation: presentation,
        page: _passportPage,
        currentWorld: _session.currentWorld,
        eye: _passportEye!,
        forward: _passportForward!,
        isCurrent: current,
        onButton: (button) => buttons[button.name] = button,
      );
      if (!current() || node == null) return;
      _passportRoot?.parent?.remove(_passportRoot!);
      adapter.scene.add(node);
      _passportRoot = node;
      _passportActions.addEntries(
        presentation.pages[_passportPage].actions.map(
          (action) => MapEntry(action.name, action),
        ),
      );
      _passportButtons
        ..clear()
        ..addAll(buttons);
      _passportFocus.replace(
        [
          ..._passportActions.keys,
          VrlzExpeditionSceneUi.acceptName,
          VrlzExpeditionSceneUi.returnName,
          VrlzExpeditionSceneUi.travelName,
          VrlzExpeditionSceneUi.nextName,
          VrlzExpeditionSceneUi.previousName,
          VrlzExpeditionSceneUi.saveName,
          VrlzExpeditionSceneUi.closeName,
        ].where(
          (name) => buttons.containsKey(name) && _canSelectPassport(name),
        ),
      );
    } catch (_) {
      if (current()) {
        _closePassport();
        setState(
          () => _saveError = 'No se pudo abrir el pasaporte. Reintenta con X.',
        );
      }
    } finally {
      _passportBuilding = false;
      if (_passportQueued) {
        _passportQueued = false;
        if (mounted && _passportOpen && !_loading && !_exiting) {
          unawaited(_rebuildPassport());
        }
      }
    }
  }

  void _removeExpeditionUi() {
    _clearWorldChange();
    _passportPrefix = const [];
    _inspectionChangeId = null;
    _passportEpoch++;
    _objectiveEpoch++;
    for (final node in [
      _passportRoot,
      _objectiveRoot,
      _totemRoot,
      _sideRouteRoot,
    ]) {
      node?.parent?.remove(node);
    }
    _passportRoot = _objectiveRoot = _totemRoot = _sideRouteRoot = null;
    _totemPosition = _passportEye = _passportForward = null;
    _passportOpen = false;
    _giverDialogue = false;
    _dialogueMissionId = null;
    _passportActions.clear();
    _passportFocus.replace(const []);
    _passportButtons.clear();
    _passportQueued = false;
    _expeditionStamp = null;
    _passportInput.reset();
    _questActor?.dispose();
    _questActor = null;
    _questOcclusion.clear();
  }

  void _passportAction(String name) {
    if (!_passportOpen ||
        _passportBuilding ||
        !_active ||
        _loading ||
        _exiting ||
        _error != null ||
        !_canSelectPassport(name)) {
      return;
    }
    final sideAction = _passportActions[name];
    if (sideAction != null) {
      _runSideAction(sideAction);
      return;
    }
    switch (name) {
      case VrlzExpeditionSceneUi.closeName:
        _closePassport();
      case VrlzExpeditionSceneUi.previousName:
      case VrlzExpeditionSceneUi.nextName:
        final pages = VrlzPassportPresentation(
          widget.expedition!,
          dialogue: _currentGiverDialogue,
          prefixPages: _passportPrefix,
        ).pages.length;
        final delta = name == VrlzExpeditionSceneUi.nextName ? 1 : -1;
        _passportPage = (_passportPage + delta) % pages;
        _passportActions.clear();
        unawaited(_rebuildPassport());
      case VrlzExpeditionSceneUi.travelName:
        final destination = _task?.destination;
        if (destination == null) return;
        if (destination == _session.currentWorld) {
          _closePassport();
        } else {
          unawaited(_travelToWorld(destination));
        }
      case VrlzExpeditionSceneUi.saveName:
        unawaited(_save());
      case VrlzExpeditionSceneUi.acceptName:
      case VrlzExpeditionSceneUi.returnName:
        final expedition = widget.expedition!,
            mission = widget.expedition!.nextMission;
        if (_task?.isSide == true ||
            mission?.giver == null ||
            !_questVisible(mission!.giver!.position, chest: true)) {
          return;
        }
        if (name == VrlzExpeditionSceneUi.acceptName) {
          if (expedition.accept(
            mission.id,
            _session.currentWorld,
            _rig.eyeCenter.storage,
          )) {
            _giverDialogue = false;
            _dialogueMissionId = null;
            _passportPage = 0;
            unawaited(_rebuildPassport());
            unawaited(_save());
          }
        } else if (expedition.complete(
          mission.id,
          _session.currentWorld,
          _rig.eyeCenter.storage,
        )) {
          _closePassport();
          _openPassport(discoveryMissionId: mission.id);
          unawaited(_save());
        }
    }
  }

  void _runSideAction(VrlzPassportAction action) {
    final expedition = widget.expedition;
    if (expedition == null ||
        !action.canRun(
          expedition,
          _session.currentWorld,
          _rig.eyeCenter.storage,
          dialogue: _currentGiverDialogue,
        )) {
      return;
    }
    if (action.kind == VrlzPassportActionKind.chooseSide ||
        action.kind == VrlzPassportActionKind.returnSide) {
      final giver = expedition.focusedSideQuest?.giver;
      if (giver == null || !_questVisible(giver.position, chest: true)) return;
    }
    bool accepted;
    switch (action.kind) {
      case VrlzPassportActionKind.focusMain:
        accepted = expedition.focusSideQuest(null);
      case VrlzPassportActionKind.focusSide:
        accepted = expedition.focusSideQuest(action.questId);
      case VrlzPassportActionKind.chooseSide:
        accepted = expedition.chooseSideQuest(
          action.questId!,
          action.choiceId!,
          _session.currentWorld,
          _rig.eyeCenter.storage,
        );
      case VrlzPassportActionKind.returnSide:
        accepted = expedition.completeSideQuest(
          action.questId!,
          _session.currentWorld,
          _rig.eyeCenter.storage,
        );
    }
    if (!accepted) return;
    if (action.kind == VrlzPassportActionKind.returnSide) {
      _closePassport();
      _openPassport(sideQuestId: action.questId);
    } else {
      if (action.kind != VrlzPassportActionKind.chooseSide) {
        _giverDialogue = false;
        _dialogueMissionId = null;
      }
      _passportPage = 0;
      unawaited(_rebuildPassport());
    }
    unawaited(_save());
  }

  void _back() {
    if (_passportOpen) {
      _closePassport();
    } else {
      unawaited(_exit());
    }
  }

  void _select(fs.Node node) {
    if (!_active || _loading || _exiting || _error != null) return;
    if (_passportOpen) {
      if (_canSelect(node)) _passportAction(node.name);
      return;
    }
    if (node.name == VrlzExpeditionSceneUi.openName) {
      if (_canSelect(node)) _openPassport();
      return;
    }
    if (_selectWorldChange(node)) return;
    final task = _task;
    if (task?.giver != null &&
        node.name == VrlzExpeditionActor.giverName(task!.actorId!)) {
      if (_canSelect(node) &&
          _questVisible(task.giver!.position, chest: true)) {
        final reaction = VrlzWorldChangePolicy.taskReaction(
          widget.expedition!,
          _session.currentWorld,
        );
        _openPassport(
          giverDialogue: true,
          inspectionTitle: reaction == null
              ? null
              : '${reaction.name} · Tu decisión',
          inspectionBody: reaction?.dialogue,
          inspectionChangeId: reaction == null
              ? null
              : widget.expedition!.worldChange(_session.currentWorld)?.id,
        );
      }
      return;
    }
    if (task?.object != null &&
        node.name == VrlzExpeditionActor.objectName(task!.actorId!)) {
      if (_canSelect(node) &&
          _questVisible(task.object!.position) &&
          task.interact(_session.currentWorld, _rig.eyeCenter.storage)) {
        _openPassport();
        unawaited(_save());
      }
      return;
    }
    final route = widget.expedition == null
        ? null
        : VrlzExpeditionRoute.current(
            widget.expedition!,
            _session.currentWorld,
          );
    if (route != null && node.name == route.name) {
      if (_canSelect(node) && _questVisible(VrlzExpeditionRoute.position)) {
        unawaited(_travelToWorld(route.destination));
      }
      return;
    }
    if (node.name.startsWith('${VrlzExpeditionSceneUi.missionName}_')) {
      final expedition = widget.expedition;
      final mission = expedition?.nextMission;
      if (_task?.isSide != true &&
          mission != null &&
          node.name == VrlzExpeditionSceneUi.objectiveName(mission.id) &&
          _questVisible(mission.position) &&
          expedition!.complete(
            mission.id,
            _session.currentWorld,
            _rig.eyeCenter.storage,
          )) {
        _openPassport(discoveryMissionId: mission.id);
        unawaited(_save());
      }
      return;
    }
    final id = _actionId(node);
    if (id == null) {
      unawaited(_travel(node));
      return;
    }
    final item = _activity?.activate(id, _rig.eyeCenter);
    if (item == null) return;
    final enabled = _activity!.indicatorEnabled(item);
    final indicator = _indicators[item.id];
    if (indicator != null) _setIndicator(indicator, enabled);
    if (item.action == 'toggleAudio') {
      _audio?.setEmitterEnabled(item.target, enabled);
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

  bool? _canSelectWorldChange(String name) {
    if (!name.startsWith('vrlz_change_') &&
        !name.startsWith('vrlz_expedition_giver_world_change_')) {
      return null;
    }
    final expedition = widget.expedition;
    if (expedition == null) return false;
    final change = expedition.worldChange(_session.currentWorld);
    if (change == null || _worldChangeOverlay?.change.id != change.id) {
      return false;
    }
    if (name == VrlzWorldChangePolicy.propName(change.id)) {
      return VrlzWorldChangePolicy.canInspect(
        expedition,
        _session.currentWorld,
        _rig.eyeCenter.storage,
        name,
      );
    }
    if (name == VrlzWorldChangePolicy.accessName(change.id)) {
      return VrlzWorldChangeTravelTicket.capture(
            expedition,
            _session.currentWorld,
            _rig.eyeCenter.storage,
            name,
          ) !=
          null;
    }
    if (name ==
        VrlzExpeditionActor.giverName(
          VrlzWorldChangePolicy.actorId(change.id),
        )) {
      return VrlzWorldChangePolicy.canTalk(
        expedition,
        _session.currentWorld,
        _rig.eyeCenter.storage,
      );
    }
    return false;
  }

  bool _selectWorldChange(fs.Node node) {
    final eligible = _canSelectWorldChange(node.name);
    if (eligible == null) return false;
    if (!eligible) return true;
    final expedition = widget.expedition!,
        change = widget.expedition!.worldChange(_session.currentWorld)!;
    final overlay = _worldChangeOverlay!;
    if (node.name == VrlzWorldChangePolicy.propName(change.id)) {
      final prop = change.prop!;
      if (_questVisible(
        prop.position,
        height: .8,
        ignoredRoot: overlay.propRoot,
      )) {
        final reaction = change.reaction;
        _openPassport(
          inspectionTitle: prop.label,
          inspectionBody:
              '${prop.description}${reaction == null ? '' : '\n${reaction.name}: ${reaction.dialogue}'}',
          inspectionChangeId: change.id,
        );
      }
    } else if (node.name == VrlzWorldChangePolicy.accessName(change.id)) {
      final ticket = VrlzWorldChangeTravelTicket.capture(
        expedition,
        _session.currentWorld,
        _rig.eyeCenter.storage,
        node.name,
      );
      if (ticket != null &&
          _questVisible(ticket.position, ignoredRoot: overlay.accessRoot)) {
        unawaited(_travelToWorld(ticket.destination, worldChange: ticket));
      }
    } else {
      final reaction = change.reaction!;
      if (_questVisible(
        reaction.position,
        chest: true,
        ignoredRoot: overlay.reaction?.root,
      )) {
        _openPassport(
          inspectionTitle: '${reaction.name} · Tu decisión',
          inspectionBody: reaction.dialogue,
          inspectionChangeId: change.id,
        );
      }
    }
    return true;
  }

  bool _canSelectPassport(String name) {
    final sideAction = _passportActions[name];
    if (sideAction != null) {
      return sideAction.canRun(
        widget.expedition!,
        _session.currentWorld,
        _rig.eyeCenter.storage,
        dialogue: _currentGiverDialogue,
      );
    }
    if (name.startsWith('vrlz_passport_side_')) return false;

    final expedition = widget.expedition,
        mission = widget.expedition?.nextMission;
    if (name == VrlzExpeditionSceneUi.acceptName) {
      return _task?.isSide != true &&
          _currentGiverDialogue &&
          mission != null &&
          expedition!.canAccept(
            mission.id,
            _session.currentWorld,
            _rig.eyeCenter.storage,
          );
    }
    if (name == VrlzExpeditionSceneUi.returnName) {
      return _task?.isSide != true &&
          _currentGiverDialogue &&
          mission != null &&
          expedition!.canComplete(
            mission.id,
            _session.currentWorld,
            _rig.eyeCenter.storage,
          );
    }
    return const {
      VrlzExpeditionSceneUi.closeName,
      VrlzExpeditionSceneUi.previousName,
      VrlzExpeditionSceneUi.nextName,
      VrlzExpeditionSceneUi.travelName,
      VrlzExpeditionSceneUi.saveName,
    }.contains(name);
  }

  bool _canSelect(fs.Node node) {
    if (!_active || _loading || _exiting || _error != null) return false;
    if (_passportOpen) {
      return !_passportBuilding && _canSelectPassport(node.name);
    }
    final changed = _canSelectWorldChange(node.name);
    if (changed != null) return changed;
    final task = _task;
    if (task?.giver != null &&
        node.name == VrlzExpeditionActor.giverName(task!.actorId!)) {
      return task.canTalk(_session.currentWorld, _rig.eyeCenter.storage);
    }
    if (task?.object != null &&
        node.name == VrlzExpeditionActor.objectName(task!.actorId!)) {
      return task.canInteract(_session.currentWorld, _rig.eyeCenter.storage);
    }
    final route = widget.expedition == null
        ? null
        : VrlzExpeditionRoute.current(
            widget.expedition!,
            _session.currentWorld,
          );
    if (route != null && node.name == route.name) {
      return route.canTravel(
        widget.expedition!,
        _session.currentWorld,
        _rig.eyeCenter.storage,
        node.name,
      );
    }
    if (node.name.startsWith('vrlz_side_route_')) return false;
    if (node.name == VrlzExpeditionSceneUi.openName) {
      return _totemPosition != null &&
          _totemPosition!.distanceToSquared(_rig.eyeCenter) <= 3.5 * 3.5;
    }
    if (node.name.startsWith('${VrlzExpeditionSceneUi.missionName}_')) {
      final expedition = widget.expedition,
          mission = widget.expedition?.nextMission;
      return _task?.isSide != true &&
          mission != null &&
          node.name == VrlzExpeditionSceneUi.objectiveName(mission.id) &&
          expedition!.canComplete(
            mission.id,
            _session.currentWorld,
            _rig.eyeCenter.storage,
          );
    }
    final action = _actionId(node);
    if (action != null) {
      return _activity?.canActivate(action, _rig.eyeCenter) ?? false;
    }
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
    final generation = _generation;
    final navigation = ++_navigationEpoch;
    final guard = VrlzExpeditionTravelGuard(generation, navigation);
    bool current() => guard.permits(
      mounted: mounted,
      active: _active,
      exiting: _exiting,
      hasError: _error != null,
      currentGeneration: _generation,
      currentNavigation: _navigationEpoch,
    );
    // Start before hiding the world: pose capture runs inside the save barrier.
    final saving = _save();
    _audio?.setActive(false);
    setState(() {
      _loading = true;
    });
    final saved = await saving;
    if (!current()) {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
        _onExpeditionChanged(force: true);
      }
      return;
    }
    if (!saved) {
      setState(() => _loading = false);
      _audio?.setActive(_active);
      _onExpeditionChanged(force: true);
      return;
    }
    if (!_session.enterPortal(portal.id)) {
      setState(() => _loading = false);
      _audio?.setActive(_active);
      _onExpeditionChanged(force: true);
      return;
    }
    _portalsArmed = false;
    if (mounted) await _openWorld();
  }

  bool _questVisible(
    List<double> position, {
    bool chest = false,
    double height = 0,
    fs.Node? ignoredRoot,
  }) {
    final adapter = _adapter;
    if (adapter == null) return false;
    final target = vm.Vector3.array(position);
    target.y += chest ? 1.0 : height;
    return _questOcclusion.visible(
      adapter.scene,
      _rig.eyeCenter,
      target,
      ignoredRoots: {
        if (_passportRoot != null) _passportRoot!,
        if (_objectiveRoot != null) _objectiveRoot!,
        if (_totemRoot != null) _totemRoot!,
        if (_sideRouteRoot != null) _sideRouteRoot!,
        if (ignoredRoot != null) ignoredRoot,
      },
    );
  }

  Future<void> _travelToWorld(
    String destination, {
    VrlzWorldChangeTravelTicket? worldChange,
  }) async {
    bool permitted() =>
        (worldChange != null
            ? worldChange.destination == destination &&
                  worldChange.permits(
                    widget.expedition!,
                    _session.currentWorld,
                    _rig.eyeCenter.storage,
                  )
            : _task?.destination == destination) &&
        (widget.expedition?.definition.worlds.containsKey(destination) ??
            false);
    if (!_active || _loading || _exiting || _error != null || !permitted()) {
      return;
    }
    final generation = _generation;
    final navigation = ++_navigationEpoch;
    final guard = VrlzExpeditionTravelGuard(generation, navigation);
    bool current() => guard.permits(
      mounted: mounted,
      active: _active,
      exiting: _exiting,
      hasError: _error != null,
      currentGeneration: _generation,
      currentNavigation: _navigationEpoch,
    );
    final saving = _save();
    _closePassport();
    _audio?.setActive(false);
    setState(() {
      _loading = true;
    });
    final saved = await saving;
    if (!current()) {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
        _onExpeditionChanged(force: true);
      }
      return;
    }
    if (!saved) {
      setState(() => _loading = false);
      _audio?.setActive(_active);
      _onExpeditionChanged(force: true);
      return;
    }
    if (!permitted() ||
        (worldChange != null &&
            !_questVisible(
              worldChange.position,
              ignoredRoot: _worldChangeOverlay?.accessRoot,
            )) ||
        !_session.selectWorld(destination)) {
      setState(() {
        _loading = false;
        _saveError = 'Este destino no está disponible en la experiencia.';
      });
      _audio?.setActive(_active);
      _onExpeditionChanged(force: true);
      return;
    }
    _portalsArmed = false;
    await _openWorld();
  }

  void _failAfterFrame(Object error, int generation) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && generation == _generation && _error == null) {
        _audio?.setActive(false);
        setState(() => _error = error);
      }
    });
  }

  void _tick(Duration _, double dt) {
    if (!_active || _loading || _exiting || _error != null) return;
    try {
      // Keyboard fallback for creator testing. VR controllers use the shared
      // SDK arbiter and StereoSceneView's locomotion policy.
      final keys = _arbiter == null && !_passportOpen
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
      _questActor?.tick(dt, _rig.eyeCenter);
      _worldChangeOverlay?.tick(dt, _rig.eyeCenter);
      _audio?.update(listenerPosition: _rig.eyeCenter, listenerYaw: _rig.yaw);
    } catch (error) {
      _failAfterFrame(error, _generation);
    }
  }

  Future<void> _exit() async {
    if (_exiting) return;
    _exiting = true;
    _navigationEpoch++;
    _audio?.setActive(false);
    if (!await _save()) {
      _exiting = false;
      _audio?.setActive(_active);
      _onExpeditionChanged(force: true);
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
    widget.expedition?.removeListener(_onExpeditionChanged);
    unawaited(_save());
    _generation++;
    _removeExpeditionUi();
    _autosave?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _arbiter?.removeListener(_onInput);
    _audio?.setActive(false);
    unawaited(_audio?.dispose());
    _adapter?.dispose();
    unawaited(_prepared?.reader.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _canPop,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _back();
    },
    child: VrWorldNavigationScope(
      onHome: _back,
      child: Focus(
        autofocus: true,
        onKeyEvent: (_, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape) {
            _back();
            return KeyEventResult.handled;
          }
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.keyX &&
              (widget.expedition?.ready ?? false)) {
            if (_passportOpen) {
              _closePassport();
            } else {
              _openPassport();
            }
            return KeyEventResult.handled;
          }
          // The App's HardwareGamepadAdapter already maps arrows/Enter/Space.
          // Standalone SDK viewers use the same policy without a second route.
          if (_arbiter == null) {
            final key = event.logicalKey;
            final x = key == LogicalKeyboardKey.arrowRight
                ? 1.0
                : key == LogicalKeyboardKey.arrowLeft
                ? -1.0
                : 0.0;
            final y = key == LogicalKeyboardKey.arrowUp
                ? 1.0
                : key == LogicalKeyboardKey.arrowDown
                ? -1.0
                : 0.0;
            if (x != 0 || y != 0) {
              _onInput(
                VrInputEvent(
                  type: VrInputType.navigate,
                  source: VrInputSource.externalPeripheral,
                  active: event is! KeyUpEvent,
                  data: {'stick': 'left', 'x': x, 'y': y},
                ),
              );
              return _passportOpen
                  ? KeyEventResult.handled
                  : KeyEventResult.ignored;
            }
            if (_passportOpen &&
                (key == LogicalKeyboardKey.enter ||
                    key == LogicalKeyboardKey.space)) {
              if (event is KeyDownEvent) {
                _onInput(
                  VrInputEvent(
                    type: VrInputType.select,
                    source: VrInputSource.externalPeripheral,
                  ),
                );
              }
              return KeyEventResult.handled;
            }
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
                  onGazeSelect: _select,
                  locomotionEnabled: !_passportOpen,
                  lookInputEnabled: !_passportOpen,
                  showHomeControl: !_passportOpen,
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
