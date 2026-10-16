import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;
import 'package:vrlizate_world/vrlizate_world.dart';

/// GPU projection of a prepared portable world. The caller validates GLB data
/// with the Apps profile before passing resources here, and owns the reader.
/// Geometry/materials are uploaded once, then reused by regional instances.
class VrlwSceneAdapter {
  VrlwSceneAdapter._(this.reader) {
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
  final scene = VrlwGuardedScene();
  late final VrRegionCache<List<VrWorldEntity>> cache;
  late final StreamSubscription<VrRegionSnapshot<List<VrWorldEntity>>>
  _subscription;
  final _parts = <String, List<_Part>>{};
  final prototypeColliders = <String, VrlwColliderSpec>{};
  late final List<VrlwAudioEmitter> audioEmitters = reader.index.audioEmitters;
  bool _dirty = true, _disposed = false;
  double _maintenance = 0;
  static const maxVisibleEntities = 128;
  static const maxPrimitiveInstances = 256;

  /// Counts all resident instances before frustum culling, per scene/eye.
  /// Stereo rendering can submit this work twice; this is not an FPS target.
  static const maxInstancedTriangles = 80000;

  static Future<VrlwSceneAdapter> create(
    VrlwPlaceReader reader,
    Map<String, Uint8List> resources, {
    required bool Function() isCurrent,
  }) async {
    final adapter = VrlwSceneAdapter._(reader);
    try {
      final models = <String, fs.Node>{};
      final textures = <String, fs.Texture2D>{};
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
            final original = primitive.material;
            final fs.Material material;
            if (original is fs.UnlitMaterial) {
              material = fs.UnlitMaterial(colorTexture: baseColor)
                ..baseColorFactor = original.baseColorFactor.clone()
                ..alphaMode = original.alphaMode
                ..vertexColorWeight = original.vertexColorWeight
                ..doubleSided = original.doubleSided;
            } else if (original is fs.PhysicallyBasedMaterial) {
              material = fs.PhysicallyBasedMaterial()
                ..baseColorFactor = original.baseColorFactor.clone()
                ..roughnessFactor = original.roughnessFactor
                ..metallicFactor = original.metallicFactor
                ..emissiveFactor = original.emissiveFactor.clone()
                ..alphaMode = original.alphaMode
                ..alphaCutoff = original.alphaCutoff
                ..vertexColorWeight = original.vertexColorWeight
                ..doubleSided = original.doubleSided
                ..baseColorTexture = baseColor ?? original.baseColorTexture
                ..normalTexture = normal ?? original.normalTexture
                ..metallicRoughnessTexture =
                    metallicRoughness ?? original.metallicRoughnessTexture
                ..emissiveTexture = emissive ?? original.emissiveTexture
                ..occlusionTexture = occlusion ?? original.occlusionTexture;
            } else {
              throw const FormatException('Unsupported portable material.');
            }
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
            parts.add(_Part(mesh, transform, triangles));
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
    if (!_dirty) return;
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
        part.mesh.addInstance(transform.multiplied(part.transform));
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
  }
}

class _Part {
  _Part(this.mesh, this.transform, this.triangles);
  final fs.InstancedMesh mesh;
  final vm.Matrix4 transform;
  final int triangles;
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
