import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../vrlizate_apps.dart';

/// Renders only the validated GLB data. The application supplies the renderer;
/// a bundle cannot install Dart code, native plugins, scripts or new abilities.
class VrzSceneViewer extends StatefulWidget {
  const VrzSceneViewer({super.key, required this.bundle, this.onExit});

  final VrzBundle bundle;
  final VoidCallback? onExit;

  @override
  State<VrzSceneViewer> createState() => _VrzSceneViewerState();
}

class _VrzSceneViewerState extends State<VrzSceneViewer> {
  _BundleScene? _scene;
  late fs.PerspectiveCamera _camera;
  late vm.Vector3 _position;
  double _yaw = 0;
  double _pitch = 0;
  Object? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _resetCamera();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(VrzSceneViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bundle, widget.bundle)) {
      _scene?.onError = null;
      _scene = null;
      _error = null;
      _resetCamera();
      unawaited(_load());
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
  }

  // Flutter Scene's GLB import reflects source Z; convert cameras with it.
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
      final scene = _BundleScene()
        ..environment = fs.EnvironmentMap.empty()
        ..environmentIntensity = 0
        ..skybox = null
        ..exposure = 1
        ..toneMapping = fs.ToneMappingMode.linear
        ..antiAliasingMode = fs.AntiAliasingMode.none
        ..directionalLight = fs.DirectionalLight(
          direction: vm.Vector3(-0.5, -1, 0.3)..normalize(),
          color: vm.Vector3.all(1),
          intensity: 100000 / 38400,
          castsShadow: false,
        );
      scene.ambientOcclusion.enabled = false;
      scene.screenSpaceReflections.enabled = false;
      scene.autoExposure.enabled = false;
      scene.postProcess.bloom.enabled = false;
      final model = await fs.Node.fromGlbBytes(
        widget.bundle.sceneBytes,
      ).timeout(const Duration(seconds: 20));
      if (!mounted || generation != _generation) return;
      scene.add(model);
      scene.onError = (error) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && generation == _generation) {
            setState(() => _error = error);
          }
        });
      };
      setState(() => _scene = scene);
    } catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error);
    }
  }

  @override
  void dispose() {
    _generation++;
    _scene?.onError = null;
    _scene = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xff101720),
    appBar: AppBar(
      title: Text(widget.bundle.manifest.title),
      leading: widget.onExit == null
          ? null
          : BackButton(onPressed: widget.onExit),
      actions: [
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
        if (_scene != null && _error == null)
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
              child: Text(
                'No se pudo mostrar esta escena.\n$_error',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),
        if (_scene != null && _error == null)
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
