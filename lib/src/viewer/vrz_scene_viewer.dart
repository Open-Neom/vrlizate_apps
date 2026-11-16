import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;
import 'package:vrlizate_scene/vrlizate_scene.dart';

import '../../vrlizate_apps.dart';
import '../bundles/vrz_glb.dart';

/// Renders only the validated GLB data in stereoscopic VR (`StereoSceneView`)
/// or optional 2D inspection mode (`SceneView`), with studio IBL, directional
/// shadows, PBR-neutral tone mapping, and automatic GLB animation playback.
/// The application supplies the renderer; a bundle cannot install Dart code,
/// native plugins, scripts, or new abilities.
class VrzSceneViewer extends StatefulWidget {
  const VrzSceneViewer({
    super.key,
    required this.bundle,
    this.onExit,
    this.initialStereoMode = true,
    this.dynamicScaling = true,
    this.quality,
    this.sgsrUpscale = VrSgsrUpscaleConfig.mobileBalanced,
    this.onQualityChanged,
  });

  final VrzBundle bundle;
  final VoidCallback? onExit;
  final bool initialStereoMode;
  final bool dynamicScaling;
  final VrQualityPreset? quality;
  final VrSgsrUpscaleConfig? sgsrUpscale;
  final void Function(VrQualityPreset)? onQualityChanged;

  @override
  State<VrzSceneViewer> createState() => _VrzSceneViewerState();
}

class _VrzSceneViewerState extends State<VrzSceneViewer> {
  static fs.EnvironmentMap? _sharedStudioEnvironment;

  _BundleScene? _scene;
  final List<fs.AnimationClip> _clips = <fs.AnimationClip>[];
  fs.Node? _model;
  late fs.PerspectiveCamera _camera;
  late StereoHeadRig _rig;
  late vm.Vector3 _position;
  late bool _stereoMode = widget.initialStereoMode;
  double _yaw = 0;
  double _pitch = 0;
  Object? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _rig = StereoHeadRig(eyeCenter: vm.Vector3(0, 1.6, 0));
    _resetCamera();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(VrzSceneViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bundle, widget.bundle)) {
      _disposeSceneResources();
      _error = null;
      _resetCamera();
      unawaited(_load());
    }
  }

  void _disposeSceneResources() {
    final model = _model;
    if (model != null) {
      for (final clip in _clips) {
        clip.pause();
        model.removeAnimationClip(clip);
      }
    }
    _clips.clear();
    _model = null;
    final previousScene = _scene;
    _scene = null;
    if (previousScene != null) {
      previousScene.onError = null;
      previousScene.root.removeAll();
      previousScene.dispose();
    }
  }

  void _resetCamera() {
    final origin = widget.bundle.manifest.cameraPosition;
    final target = widget.bundle.manifest.cameraTarget;
    _position = vm.Vector3.array(origin);
    final forward = vm.Vector3.array(target) - _position;
    forward.normalize();
    _yaw = math.atan2(forward.x, -forward.z);
    _pitch = math.asin(forward.y.clamp(-1.0, 1.0));
    _camera = fs.PerspectiveCamera(
      position: vm.Vector3.zero(),
      target: vm.Vector3.zero(),
      up: vm.Vector3(0, 1, 0),
      fovRadiansY: math.pi / 3,
      fovNear: 0.1,
      fovFar: 1000,
    );
    _updateCamera();
    final sceneOrigin = _fromSource(_position);
    final sceneTarget = _fromSource(vm.Vector3.array(target));
    final sceneDir = sceneTarget - sceneOrigin;
    if (sceneDir.length2 > 1e-12) sceneDir.normalize();
    _rig.eyeCenter.setFrom(sceneOrigin);
    _rig.bodyYaw =
        math.atan2(sceneDir.x, -sceneDir.z) - _rig.cameraRig.yaw;
    _rig.bodyPitch =
        math.asin(sceneDir.y.clamp(-1.0, 1.0)) - _rig.cameraRig.pitch;
  }

  // Flutter Scene's GLB import reflects source Z; convert 2D cameras with it.
  vm.Vector3 _fromSource(vm.Vector3 point) =>
      vm.Vector3(point.x, point.y, -point.z);

  vm.Vector3 get _forward => vm.Vector3(
    math.sin(_yaw) * math.cos(_pitch),
    math.sin(_pitch),
    -math.cos(_yaw) * math.cos(_pitch),
  );

  void _updateCamera() {
    _camera.position = _fromSource(_position);
    _camera.target = _fromSource(_position + _forward);
  }

  void _syncModeToggle(bool nextStereo) {
    if (_stereoMode == nextStereo) return;
    if (nextStereo) {
      final scenePos = _fromSource(_position);
      _rig.eyeCenter.setFrom(scenePos);
      final sceneFwd = _fromSource(_position + _forward) - scenePos;
      if (sceneFwd.length2 > 1e-12) sceneFwd.normalize();
      _rig.bodyYaw =
          math.atan2(sceneFwd.x, -sceneFwd.z) - _rig.cameraRig.yaw;
      _rig.bodyPitch =
          math.asin(sceneFwd.y.clamp(-1.0, 1.0)) - _rig.cameraRig.pitch;
    } else {
      final eye = _rig.eyeCenter;
      _position = vm.Vector3(eye.x, eye.y, -eye.z);
      final fwd = _rig.forward;
      final srcFwd = vm.Vector3(fwd.x, fwd.y, -fwd.z);
      if (srcFwd.length2 > 1e-12) srcFwd.normalize();
      _yaw = math.atan2(srcFwd.x, -srcFwd.z);
      _pitch = math.asin(srcFwd.y.clamp(-1.0, 1.0));
      _updateCamera();
    }
    setState(() => _stereoMode = nextStereo);
  }

  void _handleExit() {
    if (widget.onExit != null) {
      widget.onExit!();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    try {
      await fs.Scene.initializeStaticResources().timeout(
        const Duration(seconds: 20),
      );
      if (!mounted || generation != _generation) return;
      if (!fs.Scene.isReadyToRender) {
        throw StateError('Flutter GPU no está disponible.');
      }
      final sunDir = vm.Vector3(-0.45, -1.0, -0.28)..normalize();
      final sunColor = vm.Vector3(1.0, 0.97, 0.92);
      final sun = fs.DirectionalLight(
        direction: sunDir,
        color: sunColor,
        intensity: 2.6,
        castsShadow: true,
      );
      VrDirectionalShadowSettings.portableWorld.applyTo(sun);
      final environment =
          _sharedStudioEnvironment ??= fs.EnvironmentMap.studio();
      final skybox = fs.Skybox(
        fs.GradientSkySource(
          zenithColor: vm.Vector3(0.08, 0.19, 0.42),
          horizonColor: vm.Vector3(0.42, 0.58, 0.78),
          groundColor: vm.Vector3(0.14, 0.14, 0.16),
          sunDirection: -sunDir,
          sunColor: sunColor * 1.6,
          sunSharpness: 320,
        ),
      );
      final scene = _BundleScene()
        ..environment = environment
        ..environmentIntensity = 0.65
        ..skybox = skybox
        ..exposure = 1.0
        ..toneMapping = fs.ToneMappingMode.pbrNeutral
        ..antiAliasingMode = fs.AntiAliasingMode.msaa
        ..directionalLight = sun;
      scene.ambientOcclusion.enabled = false;
      scene.screenSpaceReflections.enabled = false;
      scene.autoExposure.enabled = false;
      scene.postProcess.bloom.enabled = false;

      final maxTex = widget.bundle.manifest.hasExtendedProfile
          ? VrzGlbExtendedLimits.maxDimension
          : VrzGlbTextureLimits.maxDimension;
      final model = await fs.Node.fromGlbBytes(
        widget.bundle.sceneBytes,
        maxTextureSize: maxTex,
        onWarning: (_) {
          throw const FormatException('Portable GLB import failed.');
        },
      ).timeout(const Duration(seconds: 20));
      if (!mounted || generation != _generation) {
        scene.dispose();
        return;
      }
      final clips = <fs.AnimationClip>[];
      for (final animation in model.parsedAnimations) {
        if (animation.endTime.isFinite && animation.endTime > 0) {
          final clip = model.createAnimationClip(animation)
            ..loop = true
            ..weight = 1.0
            ..play();
          clips.add(clip);
        }
      }
      scene.add(model);
      scene.onError = (error) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && generation == _generation) {
            setState(() => _error = error);
          }
        });
      };
      setState(() {
        _scene = scene;
        _model = model;
        _clips
          ..clear()
          ..addAll(clips);
      });
    } catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error);
    }
  }

  @override
  void dispose() {
    _generation++;
    _disposeSceneResources();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => VrWorldNavigationScope(
    onHome: _handleExit,
    child: Scaffold(
      backgroundColor: const Color(0xff101720),
      appBar: _stereoMode
          ? null
          : AppBar(
              title: Text(widget.bundle.manifest.title),
              leading: widget.onExit == null
                  ? null
                  : BackButton(onPressed: widget.onExit),
              actions: [
                IconButton(
                  tooltip: 'Modo VR Estéreo',
                  onPressed: () => _syncModeToggle(true),
                  icon: const Icon(Icons.vrpano_outlined),
                ),
                IconButton(
                  tooltip: 'Restablecer vista',
                  onPressed: () => setState(_resetCamera),
                  icon: const Icon(Icons.center_focus_strong),
                ),
              ],
            ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_scene != null && _error == null && _stereoMode)
            StereoSceneView(
              key: ValueKey((_generation, true)),
              scene: _scene!,
              rig: _rig,
              look: const VrLook(
                exposure: 1.0,
                saturation: 1.04,
                contrast: 1.05,
                bloomIntensity: 0.20,
                bloomThreshold: 0.92,
                vignetteIntensity: 0.12,
                ambientOcclusion: true,
              ),
              quality: widget.quality,
              sgsrUpscale: widget.sgsrUpscale,
              dynamicScaling: widget.dynamicScaling,
              onQualityChanged: widget.onQualityChanged,
              enableHandTracking: false,
            )
          else if (_scene != null && _error == null)
            GestureDetector(
              onPanUpdate: (event) {
                _yaw += event.delta.dx * 0.004;
                _pitch = (_pitch - event.delta.dy * 0.004).clamp(-1.4, 1.4);
                _updateCamera();
              },
              child: fs.SceneView(_scene!, camera: _camera, pixelRatio: 1),
            )
          else if (_error == null)
            const Center(child: CircularProgressIndicator())
          else
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'No se pudo mostrar esta escena.\n$_error',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _handleExit,
                      child: const Text('Volver'),
                    ),
                  ],
                ),
              ),
            ),
          if (_scene != null && _error == null && _stereoMode)
            Positioned(
              top: 12,
              right: 12,
              child: SafeArea(
                bottom: false,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: () => _syncModeToggle(false),
                      icon: const Icon(Icons.panorama_horizontal_outlined),
                      label: const Text('Vista 2D'),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      tooltip: 'Restablecer vista',
                      onPressed: () => setState(_resetCamera),
                      icon: const Icon(Icons.center_focus_strong),
                    ),
                  ],
                ),
              ),
            ),
          if (_scene != null && _error == null && !_stereoMode)
            Positioned(
              left: 16,
              bottom: 20,
              right: 16,
              child: SafeArea(
                top: false,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: () {
                        _position += _forward * 0.5;
                        _updateCamera();
                      },
                      icon: const Icon(Icons.arrow_upward),
                      label: const Text('Avanzar'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: () {
                        _position -= _forward * 0.5;
                        _updateCamera();
                      },
                      icon: const Icon(Icons.arrow_downward),
                      label: const Text('Retroceder'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: () => _syncModeToggle(true),
                      icon: const Icon(Icons.vrpano_outlined),
                      label: const Text('VR Estéreo'),
                    ),
                    const Text(
                      'Arrastra para mirar · Escena .vrlz',
                      style: TextStyle(color: Colors.white),
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

final class _BundleScene extends fs.Scene {
  void Function(Object)? onError;
  bool _failed = false;

  @override
  void renderViews(
    List<fs.RenderView> views,
    ui.Canvas canvas, {
    ui.Rect? region,
    double? pixelRatio,
  }) {
    if (_failed) return;
    try {
      super.renderViews(views, canvas, region: region, pixelRatio: pixelRatio);
    } catch (error) {
      _failed = true;
      onError?.call(error);
    }
  }
}

/// Preferred name for new callers.
typedef VrlzSceneViewer = VrzSceneViewer;
