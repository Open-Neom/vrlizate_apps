import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;
import 'package:vrlizate_world/vrlizate_world.dart';

import '../bundles/vrz_glb.dart';
import 'vrlw_world_activity.dart';
import 'vrlw_day_night.dart';

/// GPU projection of a prepared portable world. The caller validates GLB data
/// with the Apps profile before passing resources here, and owns the reader.
/// Geometry/materials are uploaded once, then reused by regional instances.
class VrlwSceneAdapter {
  VrlwSceneAdapter._(this.reader, this.activity) {
    final provider = VrlwRegionProvider(reader);
    cache = VrRegionCache(
      grid: provider.grid,
      provider: provider.load,
      maxEntries: 16,
      maxBytes: 2 * 1024 * 1024,
      prefetchRadiusCells: 1,
      retentionRadiusCells: 1,
      maxConcurrentLoads: 2,
      idleTtl: const Duration(minutes: 2),
    );
    _subscription = cache.changes.listen((_) => _dirty = true);
  }

  final VrlwPlaceReader reader;
  final VrlwWorldActivity activity;
  final scene = VrlwGuardedScene();
  late final VrRegionCache<List<VrWorldEntity>> cache;
  late final StreamSubscription<VrRegionSnapshot<List<VrWorldEntity>>>
  _subscription;
  final _parts = <String, List<_Part>>{};
  final prototypeColliders = <String, VrlwColliderSpec>{};
  late final List<VrlwAudioEmitter> audioEmitters = reader.index.audioEmitters;
  bool _dirty = true, _disposed = false;
  double _maintenance = 0;
  double _motionAccumulator = 0;
  double _lightingAccumulator = 0;
  VrlwDayNightLighting? _dayNight;
  fs.GradientSkySource? _cycleSky;
  final _nearbyMotions = <String>{};
  final _moving = <_MovingInstance>[];
  static const maxMovingPrimitiveInstances = 16;
  static const maxVisibleEntities = 128;
  static const maxPrimitiveInstances = 256;

  /// Counts all resident instances before frustum culling, per scene/eye.
  /// Stereo rendering can submit this work twice; this is not an FPS target.
  static const maxInstancedTriangles = 80000;

  static Future<VrlwSceneAdapter> create(
    VrlwPlaceReader reader,
    Map<String, Uint8List> resources, {
    required bool Function() isCurrent,
    VrlwWorldActivity? activity,
  }) async {
    final adapter = VrlwSceneAdapter._(
      reader,
      activity ?? VrlwWorldActivity(reader.index),
    );
    try {
      final models = <String, fs.Node>{};
      final textures = <String, fs.Texture2D>{};
      final materials = VrlwMaterialCache();
      final triangleCounts = Map<fs.Geometry, int>.identity();
      var primitiveCount = 0;
      const sampling = fs.TextureSampling(maxAnisotropy: 4);

      Future<fs.Texture2D?> loadTexture(
        String? textureId,
        fs.TextureContent content,
      ) async {
        if (textureId == null) return null;
        final cached = textures['$textureId:${content.name}'];
        if (cached != null) return cached;
        final meta = reader.index.resourceAt(textureId)!;
        final bytes = resources[textureId]!;
        final fs.Texture2D loaded;
        if (meta.type == 'texture.rgba8') {
          loaded = fs.Texture2D.fromPixels(
            bytes,
            meta.width!,
            meta.height!,
            content: content,
            sampling: sampling,
          );
        } else {
          loaded = await fs.Texture2D.fromEncodedBytes(
            bytes,
            content: content,
            sampling: sampling,
            maxSize: VrlwBundleCodec.maxCompressedTextureDimension,
          );
        }
        textures['$textureId:${content.name}'] = loaded;
        return loaded;
      }

      for (final binding in reader.index.prototypeBindings) {
        if (!isCurrent()) throw StateError('World opening cancelled.');
        final model = models[binding.model] ??= await fs.Node.fromGlbBytes(
          resources[binding.model]!,
          maxTextureSize: VrzGlbTextureLimits.maxDimension,
          onWarning: (_) {
            // A malformed image must not silently become a white placeholder.
            throw const FormatException('Portable GLB import failed.');
          },
        );
        if (!isCurrent()) throw StateError('World opening cancelled.');
        final baseColor = await loadTexture(
          binding.baseColorTexture,
          fs.TextureContent.color,
        );
        final normal = await loadTexture(
          binding.normalTexture,
          fs.TextureContent.normal,
        );
        final metallicRoughness = await loadTexture(
          binding.metallicRoughnessTexture,
          fs.TextureContent.data,
        );
        final emissive = await loadTexture(
          binding.emissiveTexture,
          fs.TextureContent.color,
        );
        final occlusion = await loadTexture(
          binding.occlusionTexture,
          fs.TextureContent.data,
        );
        if (!isCurrent()) throw StateError('World opening cancelled.');
        if (binding.collider != null) {
          adapter.prototypeColliders[binding.prototypeId] = binding.collider!;
        }
        final shadowMode = (binding.castsShadows ?? false)
            ? fs.ShadowCastingMode.on
            : fs.ShadowCastingMode.off;
        final parts = <_Part>[];
        void visit(fs.Node node, vm.Matrix4 parentTransform) {
          final transform = parentTransform.multiplied(node.localTransform);
          for (final primitive
              in node.mesh?.primitives ?? <fs.MeshPrimitive>[]) {
            if (++primitiveCount > 128) {
              throw const FormatException(
                'Portable world exceeds geometry group budget.',
              );
            }
            // Inspect the public CPU snapshot once for each shared geometry.
            // Counting primitive groups alone would let a small number of
            // high-detail models multiply into millions of submitted triangles.
            final triangles = triangleCounts.putIfAbsent(
              primitive.geometry,
              () => primitive.geometry.extractMeshData().triangleCount,
            );
            if (triangles <= 0) {
              throw const FormatException(
                'Portable world requires nonempty triangle geometry.',
              );
            }
            final material = materials.resolve(
              primitive.material,
              baseColor: baseColor,
              normal: normal,
              metallicRoughness: metallicRoughness,
              emissive: emissive,
              occlusion: occlusion,
            );
            final mesh = fs.InstancedMesh(
              geometry: primitive.geometry,
              material: material,
              cullInstances: true,
            );
            adapter.scene.add(
              fs.Node()
                ..raycastable = false
                ..shadowCastingMode = shadowMode
                ..addComponent(fs.InstancedMeshComponent(mesh)),
            );
            final matches = reader.index.motions.where(
              (m) =>
                  m.prototypeId == binding.prototypeId && m.node == node.name,
            );
            parts.add(
              _Part(
                mesh,
                transform,
                triangles,
                matches.isEmpty ? null : matches.single,
              ),
            );
          }
          for (final child in node.children) {
            visit(child, transform);
          }
        }

        // Runtime GLB import mirrors Z at its boundary. Cancel that mirror so
        // authored mesh coordinates agree with VRLW's +Y up / -Z forward.
        visit(model, vm.Matrix4.diagonal3Values(1, 1, -1));
        if (parts.isEmpty) {
          throw const FormatException(
            'Prototype contains no renderable geometry.',
          );
        }
        adapter._parts[binding.prototypeId] = parts;
      }
      final env = reader.index.environment;
      fs.EnvironmentMap environmentMap = fs.EnvironmentMap.empty();
      var environmentIntensity = 0.0;
      if (env?.environmentResource != null) {
        environmentMap = await fs.EnvironmentMap.fromKtx2Bytes(
          resources[env!.environmentResource!]!,
        );
        environmentIntensity = env.environmentIntensity ?? 1.0;
      } else if (env?.environmentIntensity != null) {
        environmentIntensity = env!.environmentIntensity!;
      }
      final sunDir = env?.sunDirection != null
          ? (vm.Vector3.array(env!.sunDirection!)..normalize())
          : (vm.Vector3(-.4, -1, -.2)..normalize());
      final sunColor = env?.sunColor != null
          ? vm.Vector3.array(env!.sunColor!)
          : vm.Vector3(1, .96, .9);
      adapter.scene
        ..environment = environmentMap
        ..environmentIntensity = environmentIntensity
        ..skybox = env?.skyboxResource != null
            ? fs.Skybox(fs.EnvironmentSkySource())
            : null
        ..exposure = env?.exposure ?? 1.0
        ..directionalLight = fs.DirectionalLight(
          direction: sunDir,
          color: sunColor,
          intensity: env?.sunIntensity ?? 2.5,
          castsShadow: env?.castsShadows ?? false,
        );
      final cycle = env?.dayNightCycle;
      if (cycle != null) {
        // A constant diffuse floor is cheap and needs no additional GPU bake.
        // An explicitly authored environment remains the lighting source.
        if (env?.environmentResource == null) {
          adapter.scene.environment = fs.EnvironmentMap.constantDiffuse(
            vm.Vector3(.22, .25, .32),
          );
        }
        adapter._dayNight = VrlwDayNightLighting(
          cycle,
          baseSunIntensity: env?.sunIntensity ?? 2.5,
          baseEnvironmentIntensity: env?.environmentIntensity ?? 1,
          baseExposure: env?.exposure ?? 1,
        );
        adapter._cycleSky = fs.GradientSkySource();
        adapter.scene.skybox = fs.Skybox(adapter._cycleSky!);
        adapter._updateLighting(force: true);
      }
      return adapter;
    } catch (_) {
      adapter.dispose();
      rethrow;
    }
  }

  void update(vm.Vector3 eye, double dt) {
    if (_disposed) return;
    cache.updatePosition(VrWorldPosition(eye.x, eye.y, eye.z));
    _maintenance += dt.isFinite ? dt.clamp(0, 1) : 0;
    if (_maintenance >= 5) {
      _maintenance = 0;
      cache.prune();
    }
    if (!_dirty) {
      _updateMotion(eye, dt);
      return;
    }
    _dirty = false;
    final snapshot = cache.snapshot;
    if (snapshot.errors.isNotEmpty) throw snapshot.errors.values.first;
    final entities = [
      for (final region in snapshot.resident.values) ...region.value,
    ];
    validateActiveGeometry(entities, {
      for (final entry in _parts.entries)
        entry.key: [for (final part in entry.value) part.triangles],
    });
    validateActiveMotion(entities, {
      for (final entry in _parts.entries)
        entry.key: entry.value.where((p) => p.motion != null).length,
    });
    _moving.clear();
    for (final parts in _parts.values) {
      for (final part in parts) {
        part.mesh.clearInstances();
      }
    }
    for (final entity in entities) {
      final pose = entity.transform;
      final transform =
          vm.Matrix4.translationValues(
              pose.position.x,
              pose.position.y,
              pose.position.z,
            )
            ..rotateY(pose.yawRadians)
            ..scaleByDouble(pose.scale, pose.scale, pose.scale, 1);
      for (final part in _parts[entity.prototypeId]!) {
        final motion = part.motion;
        final actual = motion == null
            ? transform.multiplied(part.transform)
            : transform
                  .multiplied(activity.delta(motion.id))
                  .multiplied(part.transform);
        final slot = part.mesh.addInstance(actual);
        if (motion != null) {
          final path = activity.pathFor(motion.id);
          final center = path?.boundsCenter ?? vm.Vector3.array(motion.pivot);
          _moving.add(
            _MovingInstance(
              part,
              slot,
              transform,
              transform.transformed3(center),
              motion.rangeMeters +
                  (path?.boundsRadius ?? motion.amplitude?.abs() ?? 0) *
                      pose.scale.abs(),
            ),
          );
        }
      }
    }
    _updateMotion(eye, dt);
  }

  void _updateMotion(vm.Vector3 eye, double dt) {
    final nearby = _nearbyMotions..clear();
    for (final moving in _moving) {
      final m = moving.part.motion!;
      if (eye.distanceToSquared(moving.center) <= moving.range * moving.range) {
        nearby.add(m.id);
      }
    }
    activity.advance(dt, nearby);
    _lightingAccumulator += dt.isFinite ? dt.clamp(0, .1) : 0;
    _updateLighting();
    _motionAccumulator += dt.isFinite ? dt.clamp(0, .1) : 0;
    if (_motionAccumulator < 1 / 30) return;
    _motionAccumulator %= 1 / 30;
    for (final moving in _moving) {
      final m = moving.part.motion!;
      if (!nearby.contains(m.id) ||
          !activity.motionEnabled(m.id) ||
          eye.distanceToSquared(moving.center) > moving.range * moving.range) {
        continue;
      }
      activity.writeDelta(m.id, moving.delta);
      moving.actual.setFrom(moving.entityTransform);
      moving.actual.multiply(moving.delta);
      moving.actual.multiply(moving.part.transform);
      // flutter_scene invalidates aggregate and per-instance bounds here, so
      // visibility follows the current pose rather than the original position.
      moving.part.mesh.setInstanceTransform(moving.slot, moving.actual);
    }
  }

  void _updateLighting({bool force = false}) {
    final lighting = _dayNight;
    if (lighting == null || (!force && _lightingAccumulator < .2)) return;
    _lightingAccumulator %= .2;
    lighting.sample(activity.activeSeconds);
    final sky = _cycleSky!;
    sky.sunDirection.setFrom(lighting.sunDirection);
    sky.sunColor.setFrom(lighting.sunColor);
    sky.zenithColor.setFrom(lighting.zenithColor);
    sky.horizonColor.setFrom(lighting.horizonColor);
    sky.groundColor.setFrom(lighting.groundColor);
    final sun = scene.directionalLight!;
    sun.direction.setFrom(lighting.lightDirection);
    sun.color.setFrom(lighting.lightColor);
    sun.intensity = lighting.sunIntensity;
    scene.environmentIntensity = lighting.environmentIntensity;
    scene.exposure = lighting.exposure;
  }

  /// Checks the complete resident set before changing any GPU instances.
  /// The moving-part budget includes paused and distant resident instances.
  static void validateActiveMotion(
    Iterable<VrWorldEntity> entities,
    Map<String, int> movingPrimitiveCounts,
  ) {
    var count = 0;
    for (final entity in entities) {
      final parts = movingPrimitiveCounts[entity.prototypeId];
      if (parts == null || parts < 0) {
        throw const FormatException('Invalid moving primitive inventory.');
      }
      count += parts;
      if (count > maxMovingPrimitiveInstances) {
        throw const FormatException(
          'Portable world exceeds 16 moving primitive instances.',
        );
      }
    }
  }

  /// Checks the complete resident set before changing any GPU instances.
  /// Triangle counts are per primitive, including repeated mesh nodes within
  /// a prototype; reusing a GPU mesh does not make its instances free to draw.
  static void validateActiveGeometry(
    Iterable<VrWorldEntity> entities,
    Map<String, List<int>> prototypeTriangles,
  ) {
    final ids = <String>{};
    var primitives = 0, triangles = 0;
    for (final entity in entities) {
      if (!ids.add(entity.id)) {
        throw const FormatException('Duplicate resident entity ID.');
      }
      if (ids.length > maxVisibleEntities) {
        throw const FormatException(
          'Portable world exceeds 128 resident entities.',
        );
      }
      final parts = prototypeTriangles[entity.prototypeId];
      if (parts == null || parts.isEmpty) {
        throw FormatException(
          'Portable world has no geometry for prototype ${entity.prototypeId}.',
        );
      }
      for (final count in parts) {
        if (count <= 0) {
          throw const FormatException(
            'Portable world requires nonempty triangle geometry.',
          );
        }
        primitives++;
        triangles += count;
        if (primitives > maxPrimitiveInstances) {
          throw const FormatException(
            'Portable world exceeds 256 resident primitive instances.',
          );
        }
        if (triangles > maxInstancedTriangles) {
          throw const FormatException(
            'Portable world exceeds 80000 resident instanced triangles. '
            'Reduce model detail or nearby instances.',
          );
        }
      }
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _subscription.cancel();
    cache.dispose();
    scene.onError = null;
    scene.root.removeAll();
    _parts.clear();
    _moving.clear();
    _nearbyMotions.clear();
  }
}

class _Part {
  _Part(this.mesh, this.transform, this.triangles, this.motion);
  final fs.InstancedMesh mesh;
  final vm.Matrix4 transform;
  final int triangles;
  final VrlwMotionSpec? motion;
}

class _MovingInstance {
  _MovingInstance(
    this.part,
    this.slot,
    this.entityTransform,
    this.center,
    this.range,
  );
  final _Part part;
  final int slot;
  final vm.Matrix4 entityTransform;
  final vm.Vector3 center;
  final double range;
  final delta = vm.Matrix4.identity();
  final actual = vm.Matrix4.identity();
}

typedef _MaterialKey = (
  fs.Material,
  fs.TextureSource?,
  fs.TextureSource?,
  fs.TextureSource?,
  fs.TextureSource?,
  fs.TextureSource?,
);

/// Reuses imported materials unless a binding overrides one of their maps.
/// The same result is shared across regional instances and both render views;
/// this does not merge separate embedded images from different GLB imports.
final class VrlwMaterialCache {
  final _materials = <_MaterialKey, fs.Material>{};

  fs.Material resolve(
    fs.Material original, {
    fs.TextureSource? baseColor,
    fs.TextureSource? normal,
    fs.TextureSource? metallicRoughness,
    fs.TextureSource? emissive,
    fs.TextureSource? occlusion,
  }) {
    if (original is! fs.UnlitMaterial &&
        original is! fs.PhysicallyBasedMaterial) {
      throw const FormatException('Unsupported portable material.');
    }
    final key = (
      original,
      baseColor,
      normal,
      metallicRoughness,
      emissive,
      occlusion,
    );
    return _materials.putIfAbsent(key, () {
      if (baseColor == null &&
          normal == null &&
          metallicRoughness == null &&
          emissive == null &&
          occlusion == null) {
        // Preserve the importer texture, sampler and all material properties.
        return original;
      }
      fs.TextureTransform transform(fs.TextureTransform source) =>
          fs.TextureTransform(
            offset: source.offset.clone(),
            scale: source.scale.clone(),
            rotation: source.rotation,
          );
      if (original is fs.UnlitMaterial) {
        return fs.UnlitMaterial(
            colorTexture: baseColor ?? original.baseColorTexture,
          )
          ..name = original.name
          ..baseColorFactor = original.baseColorFactor.clone()
          ..baseColorTextureTransform = baseColor == null
              ? transform(original.baseColorTextureTransform)
              : fs.TextureTransform()
          ..baseColorTextureTexCoord = baseColor == null
              ? original.baseColorTextureTexCoord
              : 0
          ..alphaMode = original.alphaMode
          ..vertexColorWeight = original.vertexColorWeight
          ..doubleSided = original.doubleSided
          ..displayReferred = original.displayReferred;
      }
      final physical = original as fs.PhysicallyBasedMaterial;
      return fs.PhysicallyBasedMaterial()
        ..name = physical.name
        ..baseColorFactor = physical.baseColorFactor.clone()
        ..roughnessFactor = physical.roughnessFactor
        ..metallicFactor = physical.metallicFactor
        ..emissiveFactor = physical.emissiveFactor.clone()
        ..alphaMode = physical.alphaMode
        ..alphaCutoff = physical.alphaCutoff
        ..vertexColorWeight = physical.vertexColorWeight
        ..doubleSided = physical.doubleSided
        ..baseColorTexture = baseColor ?? physical.baseColorTexture
        ..baseColorTextureTransform = baseColor == null
            ? transform(physical.baseColorTextureTransform)
            : fs.TextureTransform()
        ..baseColorTextureTexCoord = baseColor == null
            ? physical.baseColorTextureTexCoord
            : 0
        ..normalTexture = normal ?? physical.normalTexture
        ..normalTextureTransform = normal == null
            ? transform(physical.normalTextureTransform)
            : fs.TextureTransform()
        ..normalTextureTexCoord = normal == null
            ? physical.normalTextureTexCoord
            : 0
        ..metallicRoughnessTexture =
            metallicRoughness ?? physical.metallicRoughnessTexture
        ..metallicRoughnessTextureTransform = metallicRoughness == null
            ? transform(physical.metallicRoughnessTextureTransform)
            : fs.TextureTransform()
        ..metallicRoughnessTextureTexCoord = metallicRoughness == null
            ? physical.metallicRoughnessTextureTexCoord
            : 0
        ..emissiveTexture = emissive ?? physical.emissiveTexture
        ..emissiveTextureTransform = emissive == null
            ? transform(physical.emissiveTextureTransform)
            : fs.TextureTransform()
        ..emissiveTextureTexCoord = emissive == null
            ? physical.emissiveTextureTexCoord
            : 0
        ..occlusionTexture = occlusion ?? physical.occlusionTexture
        ..occlusionTextureTransform = occlusion == null
            ? transform(physical.occlusionTextureTransform)
            : fs.TextureTransform()
        ..occlusionTextureTexCoord = occlusion == null
            ? physical.occlusionTextureTexCoord
            : 0;
    });
  }
}

/// Escalates render failures to the host instead of repeating them every frame.
final class VrlwGuardedScene extends fs.Scene {
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
