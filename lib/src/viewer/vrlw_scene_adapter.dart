import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;
import 'package:vrlizate_physics/vrlizate_physics.dart';
import 'package:vrlizate_scene/vrlizate_scene.dart';
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
    this.softResidencyBudget = true,
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

  /// When `true` (default), dense chunks gracefully sort entities by squared
  /// distance to the viewer and cull distant instances above residency caps
  /// instead of aborting the session. Corrupt duplicate IDs or missing geometry
  /// still fail deterministically.
  final bool softResidencyBudget;

  /// Analytical collision, step-up, gravity, trigger, and raycast space driven
  /// by `vrlizate_physics` from active [prototypeColliders].
  final PhysicsWorldSpace physicsSpace = PhysicsWorldSpace();

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
  final _parts = <String, ({List<List<_Part>> levels, List<_Part> batches})>{};
  final _meshTransforms = Map<fs.InstancedMesh, List<vm.Matrix4>>.identity();
  final _lod = VrlwLodSelector();
  final prototypeColliders = <String, VrlwColliderSpec>{};
  late final List<VrlwAudioEmitter> audioEmitters = reader.index.audioEmitters;
  bool _dirty = true, _disposed = false;
  double _maintenance = 0;
  double _lightingAccumulator = 0;
  VrlwDayNightLighting? _dayNight;
  fs.GradientSkySource? _cycleSky;
  final _waterController = VrAnimatedWaterController();
  bool _fogFollowsDynamicHorizon = false;
  double _baseFogSunInScatter = 0.22;
  late final _motionRuntime = VrlwMotionRuntime(activity);
  List<VrWorldEntity> _residentEntities = const [];

  /// Number of water materials driven by zero-allocation GPU normal-map cycling.
  int get animatedWaterMaterialCount => _waterController.materialCount;

  /// Current active water normal-map ripple frame index.
  int get activeWaterFrameIndex => _waterController.activeFrameIndex;
  static const maxMovingPrimitiveInstances = 16;
  static const maxVisibleEntities = 128;
  static const maxPrimitiveInstances = 256;

  /// Counts all resident instances before frustum culling, per scene/eye.
  /// Stereo rendering can submit this work twice; this is not an FPS target.
  static const maxInstancedTriangles = 80000;
  static fs.EnvironmentMap? _fallbackStudio;

  /// Public read-only live transform view for [mesh] managed by this adapter,
  /// avoiding any access to internal `flutter_scene` fields during occlusion.
  List<vm.Matrix4>? instanceTransformsForMesh(fs.InstancedMesh mesh) {
    final tracked = _meshTransforms[mesh];
    return tracked == null ? null : List<vm.Matrix4>.unmodifiable(tracked);
  }

  /// Whether the chunk containing [eye] is currently decoded and synced into
  /// GPU/physics residency.
  bool isCurrentCellResident(vm.Vector3 eye) =>
      !_dirty &&
      cache.snapshot.resident.containsKey(
        cache.grid.keyAt(VrWorldPosition(eye.x, eye.y, eye.z)),
      );

  static Future<VrlwSceneAdapter> create(
    VrlwPlaceReader reader,
    Map<String, Uint8List> resources, {
    required bool Function() isCurrent,
    VrlwWorldActivity? activity,
    bool debugForceHighestLod = false,
    bool softResidencyBudget = true,
    bool hasExtendedProfile = false,
    bool allowKtx2Textures = false,
    VrQualityTier? qualityTier,
  }) async {
    final enableKtx2 = allowKtx2Textures || hasExtendedProfile;
    // Also protect direct adapter callers before creating any scene resources.
    for (final resource in reader.index.resources) {
      VrlwTexturePolicy.validateDecoder(
        resource.type,
        allowKtx2Textures: enableKtx2,
      );
      if (resource.type == 'texture.ktx2') {
        final payload = resources[resource.id];
        if (payload == null) {
          throw FormatException('Missing texture.ktx2 payload: ${resource.id}');
        }
        VrlwTexturePolicy.validateKtx2Payload(
          payload,
          declaredWidth: resource.width,
          declaredHeight: resource.height,
        );
      }
    }
    final adapter = VrlwSceneAdapter._(
      reader,
      activity ?? VrlwWorldActivity(reader.index),
      debugForceHighestLod: debugForceHighestLod,
      softResidencyBudget: softResidencyBudget,
    );
    try {
      final models = <String, fs.Node>{};
      final textures = <String, fs.TextureSource>{};
      final materials = VrSceneMaterialCache();
      // Retain only counts, never copied vertex data, between imported parts.
      final triangleCounts = Map<fs.Geometry, int>.identity();
      final geometryFingerprints = Map<fs.Geometry, String>.identity();
      var primitiveCount = 0;
      final budget = qualityTier != null
          ? VrTextureBudget.forTier(qualityTier)
          : null;
      final defaultSampling = budget != null
          ? budget.samplingForRole(VrTextureRole.heroSurface)
          : const fs.TextureSampling(maxAnisotropy: 8);
      final ormSampling = budget != null
          ? budget.samplingForRole(VrTextureRole.ormData)
          : const fs.TextureSampling(maxAnisotropy: 8);
      final maxPrimitiveGroups = hasExtendedProfile ? 512 : 128;
      final maxGlbTexDim = hasExtendedProfile
          ? (budget != null
                ? budget.maxDimensionForRole(VrTextureRole.heroSurface)
                : VrzGlbExtendedLimits.maxDimension)
          : VrzGlbTextureLimits.maxDimension;

      Future<fs.TextureSource?> loadTexture(
        String? textureId,
        fs.TextureContent content, {
        VrTextureRole role = VrTextureRole.heroSurface,
      }) async {
        if (textureId == null) return null;
        final cacheKey = '$textureId:${content.name}:${role.name}';
        final cached = textures[cacheKey];
        if (cached != null) return cached;
        final meta = reader.index.resourceAt(textureId)!;
        final bytes = resources[textureId]!;
        final activeSampling = role == VrTextureRole.ormData ||
                content == fs.TextureContent.data
            ? ormSampling
            : (role == VrTextureRole.sky
                  ? const fs.TextureSampling(maxAnisotropy: 1)
                  : defaultSampling);
        final roleCap = budget?.maxDimensionForRole(role, content: content);
        final fs.TextureSource loaded;
        if (meta.type == 'texture.ktx2') {
          loaded = await VrKtx2TextureLoader.load(
            bytes,
            content: content,
            sampling: activeSampling,
            maxTextureSize: roleCap,
          );
        } else if (meta.type == 'texture.rgba8') {
          loaded = fs.Texture2D.fromPixels(
            bytes,
            meta.width!,
            meta.height!,
            content: content,
            sampling: activeSampling,
          );
        } else {
          final formatMax = hasExtendedProfile
              ? VrlwTexturePolicy.maxKtx2Dimension
              : VrlwBundleCodec.maxCompressedTextureDimension;
          final effectiveMax = roleCap != null && roleCap < formatMax
              ? roleCap
              : formatMax;
          loaded = await fs.Texture2D.fromEncodedBytes(
            bytes,
            content: content,
            sampling: activeSampling,
            maxSize: effectiveMax,
          );
        }
        textures[cacheKey] = loaded;
        return loaded;
      }

      for (final binding in reader.index.prototypeBindings) {
        if (!isCurrent()) throw StateError('World opening cancelled.');
        final model = models[binding.model] ??= await fs.Node.fromGlbBytes(
          resources[binding.model]!,
          maxTextureSize: maxGlbTexDim,
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
          role: VrTextureRole.ormData,
        );
        final emissive = await loadTexture(
          binding.emissiveTexture,
          fs.TextureContent.color,
          role: VrTextureRole.prop,
        );
        final occlusion = await loadTexture(
          binding.occlusionTexture,
          fs.TextureContent.data,
          role: VrTextureRole.ormData,
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
            !hasExtendedProfile &&
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
        final batches = <_Part>[];
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
            if (++primitiveCount > maxPrimitiveGroups) {
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
            var material = materials.resolve(
              primitive.material,
              baseColor: baseColor,
              normal: normal,
              metallicRoughness: metallicRoughness,
              emissive: emissive,
              occlusion: occlusion,
            );
            final enableAnimatedWater =
                reader.index.environment?.animatedWater ?? true;
            if (enableAnimatedWater &&
                normal == null &&
                material is fs.PhysicallyBasedMaterial &&
                material.normalTexture == null &&
                VrWaterSurfaceClassifier.isWaterSurface(
                  prototypeId: binding.prototypeId,
                  nodeName: node.name,
                  materialName: material.name,
                )) {
              final waterFrames = VrWaterNormalBank.ensureFrames();
              if (waterFrames != null && waterFrames.isNotEmpty) {
                // Clone via cache keyed on frame 0 so non-water meshes sharing
                // the GLB source material stay completely untouched.
                material = materials.resolve(
                  material,
                  normal: waterFrames.first,
                );
              }
              if (material is fs.PhysicallyBasedMaterial) {
                adapter._waterController.register(material);
              }
            }
            final matches = reader.index.motions.where(
              (m) =>
                  m.prototypeId == binding.prototypeId && m.node == node.name,
            );
            final motion = matches.isEmpty ? null : matches.single;
            _Part createPart() {
              final batch = VrSceneMeshBatch(
                geometry: primitive.geometry,
                material: material,
                shadowCastingMode: shadowMode,
                raycastable: true,
                visible: false,
              );
              adapter.scene.add(batch.node);
              final part = _Part(
                batch.mesh,
                batch.node,
                transform,
                triangles!,
                motion,
              );
              adapter._meshTransforms[batch.mesh] = part.trackedTransforms;
              batches.add(part);
              return part;
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
        adapter._parts[binding.prototypeId] = (levels: parts, batches: batches);
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
      final cycle = env?.dayNightCycle;
      fs.EnvironmentMap environmentMap = fs.EnvironmentMap.empty();
      var environmentIntensity = 0.0;
      if (env?.environmentResource != null) {
        environmentMap = await loadEnvironment(env!.environmentResource!);
        environmentIntensity = env.environmentIntensity ?? 1.0;
      } else if (cycle == null && fs.Scene.isReadyToRender) {
        environmentMap = _fallbackStudio ??= fs.EnvironmentMap.studio();
        environmentIntensity = env?.environmentIntensity ?? 0.55;
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
        allowKtx2Textures: enableKtx2,
        resourceType: (id) => reader.index.resourceAt(id)!.type,
        fromEnvironment: (id) async =>
            vrlwEnvironmentSkybox(await loadEnvironment(id)),
        fromTexture: (id) async => vrlwTextureSkybox(
          (await loadTexture(
            id,
            fs.TextureContent.color,
            role: VrTextureRole.sky,
          ))!,
          fs.EnvironmentMap.empty(),
        ),
      );
      if (!isCurrent()) throw StateError('World opening cancelled.');
      final fallbackSkySource =
          authoredSky == null && cycle == null && fs.Scene.isReadyToRender
          ? _fallbackSkySourceForWorld(reader.index.id, sunDir, sunColor)
          : null;
      final fallbackSkybox = fallbackSkySource == null
          ? null
          : fs.Skybox(fallbackSkySource);
      final sun = fs.DirectionalLight(
        direction: sunDir,
        color: sunColor,
        intensity: env?.sunIntensity ?? 2.5,
        castsShadow: env?.castsShadows ?? false,
      );
      VrDirectionalShadowSettings.portableWorld.applyTo(sun);
      adapter.scene
        ..environment = environmentMap
        ..environmentIntensity = environmentIntensity
        ..skybox = authoredSky ?? fallbackSkybox
        ..exposure = env?.exposure ?? 1.0
        ..toneMapping = fs.ToneMappingMode.pbrNeutral
        ..directionalLight = sun;
      if (env?.environmentResource == null &&
          fallbackSkySource != null &&
          fs.Scene.isReadyToRender) {
        // Outdoor worlds without an explicit environment.ktx2 bake real sky IBL
        // from their biome gradient instead of reflecting a white studio box.
        adapter.scene
          ..skyEnvironment = fs.SkyEnvironment(
            fallbackSkySource,
            faceResolution: 64,
            equirectWidth: 256,
            refresh: fs.SkyEnvironmentRefresh.manual,
          )
          ..environmentIntensity = env?.environmentIntensity ?? 0.85;
      }

      // Apply explicit .vrlw atmospheric height-fog or biome-matched aerial haze.
      final biomeFog = VrAtmosphericFogProfile.forWorldId(
        reader.index.id,
        horizonColor: fallbackSkySource?.horizonColor,
      );
      final fogProfile = VrAtmosphericFogProfile(
        enabled: (env?.fogDensity ?? biomeFog.density) > 0.0,
        color: env?.fogColor != null
            ? vm.Vector3.array(env!.fogColor!)
            : biomeFog.color,
        density: env?.fogDensity ?? biomeFog.density,
        maxOpacity: env?.fogMaxOpacity ?? biomeFog.maxOpacity,
        heightFalloff: env?.fogHeightFalloff ?? biomeFog.heightFalloff,
        cutoffDistance: env?.fogCutoffDistance ?? biomeFog.cutoffDistance,
        skyColorInfluence:
            env?.fogSkyColorInfluence ?? biomeFog.skyColorInfluence,
        sunInScatter: env?.fogSunInScatter ?? biomeFog.sunInScatter,
      );
      fogProfile.applyTo(adapter.scene);
      adapter._fogFollowsDynamicHorizon = env?.fogColor == null;
      adapter._baseFogSunInScatter = fogProfile.sunInScatter;

      if (cycle != null) {
        // Keep studio/sky prefiltered radiance when the GPU is active so metals,
        // glass, and water preserve crisp specular reflections across the cycle;
        // fall back to constant diffuse only in headless tests without GPU.
        if (env?.environmentResource == null && !fs.Scene.isReadyToRender) {
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
          if (env?.environmentResource == null && fs.Scene.isReadyToRender) {
            adapter.scene.skyEnvironment = fs.SkyEnvironment(
              adapter._cycleSky!,
              faceResolution: 64,
              equirectWidth: 256,
              refresh: fs.SkyEnvironmentRefresh.interval,
              interval: const Duration(milliseconds: 2500),
            );
          }
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
      final allEntities = [
        for (final region in snapshot.resident.values) ...region.value,
      ];
      final protoTriangles = {
        for (final entry in _parts.entries)
          entry.key: [
            for (final part in entry.value.levels.first) part.triangles,
          ],
      };
      final movingCounts = {
        for (final entry in _parts.entries)
          entry.key: entry.value.levels.first
              .where((p) => p.motion != null)
              .length,
      };
      final List<VrWorldEntity> admitted;
      if (softResidencyBudget) {
        admitted = selectWithinBudget(
          allEntities,
          protoTriangles,
          movingCounts,
          eye,
        );
      } else {
        validateActiveGeometry(allEntities, protoTriangles);
        validateActiveMotion(allEntities, movingCounts);
        admitted = allEntities;
      }
      // Colliders cover all resident entities in the active chunk neighborhood
      // so distant/culled walls never become pass-through!
      physicsSpace.replaceColliders([
        for (final entity in allEntities)
          if (prototypeColliders[entity.prototypeId] case final spec?)
            PhysicsWorldCollider.fromEntity(
              id: entity.id,
              entityX: entity.transform.position.x,
              entityY: entity.transform.position.y,
              entityZ: entity.transform.position.z,
              yawRadians: entity.transform.yawRadians,
              scale: entity.transform.scale,
              shapeName: spec.shape,
              halfExtents: spec.halfExtents,
              radius: spec.radius,
              height: spec.height,
              offset: spec.offset,
            ),
      ]);
      _residentEntities = admitted;
      _lod.replaceEntities(admitted);
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
    if (regionsChanged) {
      _motionRuntime.clear();
    }
    final rebuildAll =
        regionsChanged ||
        changedPrototypes.any(
          (proto) =>
              _parts[proto]?.batches.any((part) => part.motion != null) ??
              false,
        );
    if (rebuildAll && !regionsChanged) {
      _motionRuntime.clear();
    }
    for (final entry in _parts.entries) {
      if (!rebuildAll && !changedPrototypes.contains(entry.key)) continue;
      // A static batch can serve multiple levels. Clear its retained instances
      // once, and avoid advancing its mesh revision if it is already empty.
      for (final part in entry.value.batches) {
        part.trackedTransforms.clear();
        if (part.mesh.instanceCount > 0) {
          part.mesh.clearInstances();
        }
      }
    }
    for (final entity in _residentEntities) {
      if (!rebuildAll && !changedPrototypes.contains(entity.prototypeId)) {
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
      for (final part in _parts[entity.prototypeId]!.levels[level]) {
        final motion = part.motion;
        final actual = motion == null
            ? transform.multiplied(part.transform)
            : transform
                  .multiplied(activity.delta(motion.id))
                  .multiplied(part.transform);
        final slot = part.mesh.addInstance(actual);
        part.trackedTransforms.add(actual.clone());
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
      if (!rebuildAll && !changedPrototypes.contains(entry.key)) continue;
      for (final part in entry.value.batches) {
        part.node.visible = part.mesh.instanceCount > 0;
      }
    }
    _updateMotion(eye, dt);
  }

  void _updateMotion(vm.Vector3 eye, double dt) {
    _motionRuntime.update(eye, dt);
    _waterController.update(dt);
    _lightingAccumulator += dt.isFinite ? dt.clamp(0, .1) : 0;
    _updateLighting();
  }

  static const double _lightingStepSeconds = 1 / 30;

  void _updateLighting({bool force = false}) {
    final lighting = _dayNight;
    if (lighting == null ||
        (!force && _lightingAccumulator < _lightingStepSeconds)) {
      return;
    }
    _lightingAccumulator %= _lightingStepSeconds;
    lighting.sample(activity.activeSeconds);
    final sky = _cycleSky;
    if (sky != null) {
      sky.sunDirection.setFrom(lighting.sunDirection);
      sky.sunColor.setFrom(lighting.sunColor);
      sky.zenithColor.setFrom(lighting.zenithColor);
      sky.horizonColor.setFrom(lighting.horizonColor);
      sky.groundColor.setFrom(lighting.groundColor);
    }
    if (_fogFollowsDynamicHorizon) {
      VrAtmosphericFogProfile.syncDynamicHorizon(
        scene,
        horizonColor: lighting.horizonColor,
        sunAltitude: lighting.sunDirection.y,
        baseSunInScatter: _baseFogSunInScatter,
      );
    }
    final sun = scene.directionalLight!;
    sun.direction.setFrom(lighting.lightDirection);
    sun.color.setFrom(lighting.lightColor);
    sun.intensity = lighting.sunIntensity;
    scene.environmentIntensity = lighting.environmentIntensity;
    scene.exposure = lighting.exposure;
  }

  static fs.GradientSkySource _fallbackSkySourceForWorld(
    String worldId,
    vm.Vector3 sunDir,
    vm.Vector3 sunColor,
  ) {
    final id = worldId.toLowerCase();
    var zenith = vm.Vector3(0.09, 0.22, 0.48);
    var horizon = vm.Vector3(0.46, 0.62, 0.82);
    var ground = vm.Vector3(0.16, 0.15, 0.14);
    var sunScale = 1.8;
    var sharpness = 320.0;

    if (id.contains('lunar') ||
        id.contains('spaceport') ||
        id.contains('orbital') ||
        id.contains('astral')) {
      zenith = vm.Vector3(0.008, 0.012, 0.032);
      horizon = vm.Vector3(0.035, 0.055, 0.115);
      ground = vm.Vector3(0.06, 0.06, 0.07);
      sunScale = 2.6;
      sharpness = 720.0;
    } else if (id.contains('volcanic')) {
      zenith = vm.Vector3(0.08, 0.025, 0.02);
      horizon = vm.Vector3(0.52, 0.16, 0.05);
      ground = vm.Vector3(0.18, 0.05, 0.02);
      sunScale = 2.2;
      sharpness = 220.0;
    } else if (id.contains('cavern') || id.contains('fungal')) {
      zenith = vm.Vector3(0.02, 0.04, 0.09);
      horizon = vm.Vector3(0.07, 0.18, 0.26);
      ground = vm.Vector3(0.03, 0.05, 0.07);
      sunScale = 0.8;
      sharpness = 140.0;
    } else if (id.contains('coral')) {
      zenith = vm.Vector3(0.02, 0.16, 0.28);
      horizon = vm.Vector3(0.06, 0.38, 0.48);
      ground = vm.Vector3(0.03, 0.10, 0.14);
      sunScale = 1.1;
      sharpness = 120.0;
    } else if (id.contains('neon') || id.contains('cypherpunk')) {
      zenith = vm.Vector3(0.03, 0.02, 0.11);
      horizon = vm.Vector3(0.24, 0.08, 0.32);
      ground = vm.Vector3(0.04, 0.03, 0.07);
      sunScale = 1.3;
      sharpness = 260.0;
    }

    return fs.GradientSkySource(
      zenithColor: zenith,
      horizonColor: horizon,
      groundColor: ground,
      sunDirection: -sunDir,
      sunColor: sunColor * sunScale,
      sunSharpness: sharpness,
    );
  }

  /// Validates structural integrity (unique IDs, valid prototype geometry and
  /// motion counts) and selects the nearest subset of [entities] to [eye] that
  /// fits within the resident entity, primitive, triangle, and motion budgets.
  static List<VrWorldEntity> selectWithinBudget(
    Iterable<VrWorldEntity> entities,
    Map<String, List<int>> prototypeTriangles,
    Map<String, int> movingPrimitiveCounts,
    vm.Vector3 eye,
  ) {
    final list = entities.toList(growable: false);
    final ids = <String>{};
    var totalPrimitives = 0;
    var totalTriangles = 0;
    var totalMoving = 0;
    for (final entity in list) {
      if (!ids.add(entity.id)) {
        throw const FormatException('Duplicate resident entity ID.');
      }
      final parts = prototypeTriangles[entity.prototypeId];
      if (parts == null || parts.isEmpty) {
        throw FormatException(
          'Portable world has no geometry for prototype ${entity.prototypeId}.',
        );
      }
      final moving = movingPrimitiveCounts[entity.prototypeId];
      if (moving == null || moving < 0) {
        throw const FormatException('Invalid moving primitive inventory.');
      }
      for (final count in parts) {
        if (count <= 0) {
          throw const FormatException(
            'Portable world requires nonempty triangle geometry.',
          );
        }
        totalPrimitives++;
        totalTriangles += count;
      }
      totalMoving += moving;
    }
    if (list.length <= maxVisibleEntities &&
        totalPrimitives <= maxPrimitiveInstances &&
        totalTriangles <= maxInstancedTriangles &&
        totalMoving <= maxMovingPrimitiveInstances) {
      return list;
    }
    final ex = eye.x.isFinite ? eye.x : 0.0;
    final ey = eye.y.isFinite ? eye.y : 0.0;
    final ez = eye.z.isFinite ? eye.z : 0.0;
    final ranked = <({VrWorldEntity entity, double dist2})>[
      for (final entity in list)
        (
          entity: entity,
          dist2: () {
            final p = entity.transform.position;
            final dx = p.x - ex;
            final dy = p.y - ey;
            final dz = p.z - ez;
            return dx * dx + dy * dy + dz * dz;
          }(),
        ),
    ]..sort((a, b) {
      final cmp = a.dist2.compareTo(b.dist2);
      return cmp != 0 ? cmp : a.entity.id.compareTo(b.entity.id);
    });

    final selected = <VrWorldEntity>[];
    var usedPrimitives = 0;
    var usedTriangles = 0;
    var usedMoving = 0;
    for (final item in ranked) {
      if (selected.length >= maxVisibleEntities) break;
      final entity = item.entity;
      final parts = prototypeTriangles[entity.prototypeId]!;
      final moving = movingPrimitiveCounts[entity.prototypeId]!;
      var entityTris = 0;
      for (final count in parts) {
        entityTris += count;
      }
      if (usedPrimitives + parts.length > maxPrimitiveInstances ||
          usedTriangles + entityTris > maxInstancedTriangles ||
          usedMoving + moving > maxMovingPrimitiveInstances) {
        continue;
      }
      selected.add(entity);
      usedPrimitives += parts.length;
      usedTriangles += entityTris;
      usedMoving += moving;
    }
    return selected;
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
    physicsSpace.clear();
    scene.onError = null;
    scene.root.removeAll();
    // SceneView(scene) does not own an application-supplied scene. Removing
    // nodes alone leaves this scene's per-eye render rings and history targets
    // retained until GC. Explicit disposal drops those references now; native
    // GPU memory can still be collected/released asynchronously by the engine.
    scene.dispose();
    _parts.clear();
    _meshTransforms.clear();
    _residentEntities = const [];
    _lod.clear();
    _motionRuntime.clear();
    _waterController.clear();
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
  _Part(this.mesh, this.node, this.transform, this.triangles, this.motion) {
    if (motion != null) {
      motionBatch = VrlwMotionBatch(
        (write) => mesh.updateInstanceTransforms(
          (transforms) {
            write(transforms);
            final count = transforms.length < trackedTransforms.length
                ? transforms.length
                : trackedTransforms.length;
            for (var i = 0; i < count; i++) {
              trackedTransforms[i].setFrom(transforms[i]);
            }
          },
          // Validated spin/bob/path deltas contain only translation and proper
          // rotation: they cannot change local winding.
          recomputeWinding: false,
        ),
      );
    }
  }
  final fs.InstancedMesh mesh;
  final fs.Node node;
  final vm.Matrix4 transform;
  final int triangles;
  final VrlwMotionSpec? motion;
  final List<vm.Matrix4> trackedTransforms = <vm.Matrix4>[];
  VrlwMotionBatch? motionBatch;
}

// Retain the previous name for callers of this viewer implementation.
typedef VrlwMaterialCache = VrSceneMaterialCache;

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
