import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;
import 'package:vrlizate_world/vrlizate_world.dart';

import '../bundles/vrz_glb.dart';
import '../bundles/vrlw_texture_policy.dart';
import 'vrlw_resident_changes.dart';
import 'vrlw_lod_selector.dart';
import 'vrlw_motion_runtime.dart';
import 'vrlw_static_part_pool.dart';
import 'vrlw_skybox.dart';
import 'vrlw_world_activity.dart';
import 'vrlw_day_night.dart';

/// GPU projection of a prepared portable world. The caller validates GLB data
/// with the Apps profile before passing resources here, and owns the reader.
/// Geometry/materials are uploaded once, then reused by regional instances.
class VrlwSceneAdapter {
  VrlwSceneAdapter._(
    this.reader,
    this.activity, {
    bool debugForceHighestLod = false,
  }) : _forceHighestLod = debugForceHighestLod {
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
    _subscription = cache.changes.listen((snapshot) {
      if (_residentChanges.update(snapshot)) _dirty = true;
    });
  }

  final VrlwPlaceReader reader;
  final VrlwWorldActivity activity;

  /// Diagnostic override for comparing full-detail and authored LOD.
  /// This does not change the world format, admission budgets or motion rates.
  bool get debugForceHighestLod => _forceHighestLod;
  bool _forceHighestLod;

  /// Change only geometry selection, retaining pose, progress, imported
  /// resources and motion phases. Rebuild the affected residency next update.
  void setDistanceLod(bool enabled) {
    if (_disposed || _forceHighestLod == !enabled) return;
    _forceHighestLod = !enabled;
    _dirty = true;
  }

  final scene = VrlwGuardedScene();
  late final VrRegionCache<List<VrWorldEntity>> cache;
  late final StreamSubscription<VrRegionSnapshot<List<VrWorldEntity>>>
  _subscription;
  final _residentChanges = VrlwResidentChanges<List<VrWorldEntity>>();
  final _parts = <String, List<List<_Part>>>{};
  final _lod = VrlwLodSelector();
  final prototypeColliders = <String, VrlwColliderSpec>{};
  late final List<VrlwAudioEmitter> audioEmitters = reader.index.audioEmitters;
  bool _dirty = true, _disposed = false;
  double _maintenance = 0;
  double _lightingAccumulator = 0;
  VrlwDayNightLighting? _dayNight;
  fs.GradientSkySource? _cycleSky;
  late final _motionRuntime = VrlwMotionRuntime(activity);
  List<VrWorldEntity> _residentEntities = const [];
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
    bool debugForceHighestLod = false,
  }) async {
    // Also protect direct adapter callers before creating any scene resources.
    for (final resource in reader.index.resources) {
      VrlwTexturePolicy.validateDecoder(resource.type);
    }
    final adapter = VrlwSceneAdapter._(
      reader,
      activity ?? VrlwWorldActivity(reader.index),
      debugForceHighestLod: debugForceHighestLod,
    );
    try {
      final models = <String, fs.Node>{};
      final textures = <String, fs.Texture2D>{};
      final materials = VrlwMaterialCache();
      // Retain only counts, never copied vertex data, between imported parts.
      final triangleCounts = Map<fs.Geometry, int>.identity();
      final geometryFingerprints = Map<fs.Geometry, String>.identity();
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
        final hasLod = binding.lods.isNotEmpty;
        if (hasLod &&
            reader.index.motions.any(
              (motion) => motion.prototypeId == binding.prototypeId,
            )) {
          throw const FormatException(
            'Portable LOD prototypes must be static.',
          );
        }
        final parts = List.generate(
          hasLod ? binding.lods.length : 1,
          (_) => <_Part>[],
        );
        final levelRoots = <String, int>{
          for (var i = 0; i < binding.lods.length; i++) binding.lods[i].node: i,
        };
        final seenRoots = <int>{};
        final detailedBounds = _LodBoundsAccumulator();
        // Scoped to this prototype: independent LOD rebuilds must never clear
        // instances belonging to a different prototype's batch. The pool keeps
        // hashes and part references only, never extracted geometry snapshots.
        final sharedStaticParts = VrlwStaticPartPool<_Part>();
        void visit(fs.Node node, vm.Matrix4 parentTransform, int? level) {
          final declaredLevel = levelRoots[node.name];
          if (declaredLevel != null) {
            if (level != null || !seenRoots.add(declaredLevel)) {
              throw const FormatException('Ambiguous or nested LOD root.');
            }
            level = declaredLevel;
          }
          final transform = parentTransform.multiplied(node.localTransform);
          for (final primitive
              in node.mesh?.primitives ?? <fs.MeshPrimitive>[]) {
            if (++primitiveCount > 128) {
              throw const FormatException(
                'Portable world exceeds geometry group budget.',
              );
            }
            // Count every resident instance against its actual geometry.
            // Bounds snapshots are transient and scoped to this part import;
            // transformed LOD0 reuse may rescan a shared mesh at import time.
            if (level == null) {
              throw const FormatException(
                'Geometry outside the declared LOD roots.',
              );
            }
            var triangles = triangleCounts[primitive.geometry];
            final needsBounds = hasLod && level == 0;
            var fingerprint = geometryFingerprints[primitive.geometry];
            if (triangles == null ||
                needsBounds ||
                (hasLod && fingerprint == null)) {
              final snapshot = primitive.geometry.extractMeshData();
              triangles ??= snapshot.triangleCount;
              triangleCounts[primitive.geometry] = triangles;
              if (needsBounds) {
                detailedBounds.include(snapshot.positions, transform);
              }
              if (hasLod && fingerprint == null) {
                fingerprint = vrlwGeometryFingerprint(
                  vertexCount: snapshot.vertexCount,
                  primitiveType: snapshot.primitiveType.index,
                  // Required to preserve the engine's importer handedness.
                  // ignore: invalid_use_of_internal_member
                  sourceWindingFlipped: primitive.geometry.sourceWindingFlipped,
                  positions: snapshot.positions,
                  normals: snapshot.normals,
                  texCoords: snapshot.texCoords,
                  texCoords1: snapshot.texCoords1,
                  colors: snapshot.colors,
                  tangents: snapshot.tangents,
                  indices: snapshot.indices,
                  customAttributes: {
                    for (final entry in snapshot.customAttributes.entries)
                      entry.key: (
                        components: entry.value.components,
                        data: entry.value.data,
                      ),
                  },
                );
                geometryFingerprints[primitive.geometry] = fingerprint;
              }
            }
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
            final matches = reader.index.motions.where(
              (m) =>
                  m.prototypeId == binding.prototypeId && m.node == node.name,
            );
            final motion = matches.isEmpty ? null : matches.single;
            _Part createPart() {
              final mesh = fs.InstancedMesh(
                geometry: primitive.geometry,
                material: material,
                cullInstances: true,
              );
              final renderNode = fs.Node()
                ..raycastable = false
                ..visible = false
                ..shadowCastingMode = shadowMode
                ..addComponent(fs.InstancedMeshComponent(mesh));
              adapter.scene.add(renderNode);
              return _Part(mesh, renderNode, transform, triangles!, motion);
            }

            parts[level].add(
              hasLod && motion == null
                  ? sharedStaticParts.resolve(
                      level: level,
                      geometryFingerprint: fingerprint!,
                      transform: transform.storage,
                      material: material,
                      shadowMode: shadowMode,
                      create: createPart,
                    )
                  : createPart(),
            );
          }
          for (final child in node.children) {
            visit(child, transform, level);
          }
        }

        // Runtime GLB import mirrors Z at its boundary. Cancel that mirror so
        // authored mesh coordinates agree with VRLW's +Y up / -Z forward.
        visit(model, vm.Matrix4.diagonal3Values(1, 1, -1), hasLod ? null : 0);
        if (parts.any((level) => level.isEmpty) ||
            (hasLod && seenRoots.length != binding.lods.length)) {
          throw const FormatException(
            'Prototype contains no renderable geometry.',
          );
        }
        adapter._parts[binding.prototypeId] = parts;
        if (hasLod) {
          adapter._lod.register(
            binding.prototypeId,
            VrlwLodPolicy(
              minDistancesMeters: binding.lods.map(
                (level) => level.minDistanceMeters,
              ),
              hysteresisMeters: binding.lodHysteresisMeters,
              bounds: detailedBounds.finish(),
            ),
          );
        }
      }
      triangleCounts.clear();
      final env = reader.index.environment;
      final environments = <String, Future<fs.EnvironmentMap>>{};
      Future<fs.EnvironmentMap> loadEnvironment(String id) =>
          environments.putIfAbsent(
            id,
            () => fs.EnvironmentMap.fromKtx2Bytes(resources[id]!),
          );
      fs.EnvironmentMap environmentMap = fs.EnvironmentMap.empty();
      var environmentIntensity = 0.0;
      if (env?.environmentResource != null) {
        environmentMap = await loadEnvironment(env!.environmentResource!);
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
      final authoredSky = await loadVrlwAuthoredSky<fs.Skybox>(
        env,
        resourceType: (id) => reader.index.resourceAt(id)!.type,
        fromEnvironment: (id) async =>
            vrlwEnvironmentSkybox(await loadEnvironment(id)),
        fromTexture: (id) async => vrlwTextureSkybox(
          (await loadTexture(id, fs.TextureContent.color))!,
          fs.EnvironmentMap.empty(),
        ),
      );
      if (!isCurrent()) throw StateError('World opening cancelled.');
      adapter.scene
        ..environment = environmentMap
        ..environmentIntensity = environmentIntensity
        ..skybox = authoredSky
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
        if (authoredSky == null) {
          adapter._cycleSky = fs.GradientSkySource();
          adapter.scene.skybox = fs.Skybox(adapter._cycleSky!);
        }
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
    final position = VrWorldPosition(eye.x, eye.y, eye.z);
    cache.updatePosition(position);
    _maintenance += dt.isFinite ? dt.clamp(0, 1) : 0;
    if (_maintenance >= 5) {
      _maintenance = 0;
      cache.prune();
    }
    if (_dirty) {
      final snapshot = cache.snapshot;
      if (snapshot.errors.isNotEmpty) throw snapshot.errors.values.first;
      final entities = [
        for (final region in snapshot.resident.values) ...region.value,
      ];
      // Always admit the full near-detail cost. Approaching an object cannot
      // invalidate a world that happened to be cheap at its entry point.
      validateActiveGeometry(entities, {
        for (final entry in _parts.entries)
          entry.key: [for (final part in entry.value.first) part.triangles],
      });
      validateActiveMotion(entities, {
        for (final entry in _parts.entries)
          entry.key: entry.value.first.where((p) => p.motion != null).length,
      });
      _residentEntities = entities;
      _lod.replaceEntities(entities);
    }
    final lodChanged =
        !debugForceHighestLod && _lod.update(position, dt, force: _dirty);
    if (!_dirty && !lodChanged) {
      _updateMotion(eye, dt);
      return;
    }
    final regionsChanged = _dirty;
    final changedPrototypes = _lod.changedPrototypeIds;
    _dirty = false;
    // LOD is restricted to static prototypes: moving slots remain valid when
    // only a static band's membership changes. Region changes still rebuild all.
    if (regionsChanged) _motionRuntime.clear();
    for (final entry in _parts.entries) {
      if (!regionsChanged && !changedPrototypes.contains(entry.key)) continue;
      final levels = entry.value;
      for (final parts in levels) {
        for (final part in parts) {
          part.mesh.clearInstances();
        }
      }
    }
    for (final entity in _residentEntities) {
      if (!regionsChanged && !changedPrototypes.contains(entity.prototypeId)) {
        continue;
      }
      final pose = entity.transform;
      final transform =
          vm.Matrix4.translationValues(
              pose.position.x,
              pose.position.y,
              pose.position.z,
            )
            ..rotateY(pose.yawRadians)
            ..scaleByDouble(pose.scale, pose.scale, pose.scale, 1);
      final level = debugForceHighestLod ? 0 : _lod.levelFor(entity.id);
      for (final part in _parts[entity.prototypeId]![level]) {
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
          _motionRuntime.add(
            batch: part.motionBatch!,
            motionId: motion.id,
            slot: slot,
            entityTransform: transform,
            localTransform: part.transform,
            center: transform.transformed3(center),
            range:
                motion.rangeMeters +
                (path?.boundsRadius ?? motion.amplitude?.abs() ?? 0) *
                    pose.scale.abs(),
          );
        }
      }
    }
    // Empty LOD batches retain reusable resources but skip mesh refresh and
    // render passes until selected again. Scene still visits the hidden nodes.
    for (final entry in _parts.entries) {
      if (!regionsChanged && !changedPrototypes.contains(entry.key)) continue;
      for (final parts in entry.value) {
        for (final part in parts) {
          part.node.visible = part.mesh.instanceCount > 0;
        }
      }
    }
    _updateMotion(eye, dt);
  }

  void _updateMotion(vm.Vector3 eye, double dt) {
    _motionRuntime.update(eye, dt);
    _lightingAccumulator += dt.isFinite ? dt.clamp(0, .1) : 0;
    _updateLighting();
  }

  void _updateLighting({bool force = false}) {
    final lighting = _dayNight;
    if (lighting == null || (!force && _lightingAccumulator < .2)) return;
    _lightingAccumulator %= .2;
    lighting.sample(activity.activeSeconds);
    final sky = _cycleSky;
    if (sky != null) {
      sky.sunDirection.setFrom(lighting.sunDirection);
      sky.sunColor.setFrom(lighting.sunColor);
      sky.zenithColor.setFrom(lighting.zenithColor);
      sky.horizonColor.setFrom(lighting.horizonColor);
      sky.groundColor.setFrom(lighting.groundColor);
    }
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
    _residentChanges.clear();
    scene.onError = null;
    scene.root.removeAll();
    // SceneView(scene) does not own an application-supplied scene. Removing
    // nodes alone leaves this scene's per-eye render rings and history targets
    // retained until GC. Explicit disposal drops those references now; native
    // GPU memory can still be collected/released asynchronously by the engine.
    scene.dispose();
    _parts.clear();
    _residentEntities = const [];
    _lod.clear();
    _motionRuntime.clear();
  }
}

/// Scanned once during import, with authored node transforms and the importer's
/// handedness already resolved. No vertex traversal occurs during LOD updates.
class _LodBoundsAccumulator {
  double minX = double.infinity, minY = double.infinity, minZ = double.infinity;
  double maxX = double.negativeInfinity,
      maxY = double.negativeInfinity,
      maxZ = double.negativeInfinity;
  final point = vm.Vector3.zero();

  void include(Float32List positions, vm.Matrix4 transform) {
    for (var i = 0; i < positions.length; i += 3) {
      point.setValues(positions[i], positions[i + 1], positions[i + 2]);
      transform.transform3(point);
      if (point.x < minX) minX = point.x;
      if (point.y < minY) minY = point.y;
      if (point.z < minZ) minZ = point.z;
      if (point.x > maxX) maxX = point.x;
      if (point.y > maxY) maxY = point.y;
      if (point.z > maxZ) maxZ = point.z;
    }
  }

  VrlwLodBounds finish() => VrlwLodBounds(
    minX: minX,
    minY: minY,
    minZ: minZ,
    maxX: maxX,
    maxY: maxY,
    maxZ: maxZ,
  );
}

class _Part {
  _Part(this.mesh, this.node, this.transform, this.triangles, this.motion)
    : motionBatch = motion == null
          ? null
          : VrlwMotionBatch(
              (write) => mesh.updateInstanceTransforms(
                write,
                // Validated spin/bob/path deltas contain only translation and
                // proper rotation: they cannot change local winding, including
                // a mirrored entity or GLB transform. Initial addInstance has
                // already captured that parity. Parent-node parity is handled
                // separately by flutter_scene. If scaling/reflection becomes a
                // motion kind, this contract must change. The batch API still
                // invalidates aggregate/per-instance bounds and GPU data.
                recomputeWinding: false,
              ),
            );
  final fs.InstancedMesh mesh;
  final fs.Node node;
  final vm.Matrix4 transform;
  final int triangles;
  final VrlwMotionSpec? motion;
  final VrlwMotionBatch? motionBatch;
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
