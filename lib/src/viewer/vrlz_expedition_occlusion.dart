import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

/// Current resident geometry only. Scene's stock picker does not yet test
/// InstancedMesh, so quest actions perform this bounded CPU check on selection,
/// never during frame/gaze filtering. Motion instance matrices are read live.
final class VrlzExpeditionOcclusion {
  // Region eviction must also allow its decoded CPU geometry to be collected.
  Expando<fs.MeshData> _geometry = Expando<fs.MeshData>();
  void clear() => _geometry = Expando<fs.MeshData>();

  fs.MeshData _data(fs.Geometry geometry) =>
      _geometry[geometry] ??= geometry.extractMeshData();

  static bool _transparent(fs.Material material) =>
      material is fs.PhysicallyBasedMaterial &&
      material.alphaMode == fs.AlphaMode.blend;

  bool visible(
    fs.Scene scene,
    vm.Vector3 eye,
    vm.Vector3 target, {
    Set<fs.Node> ignoredRoots = const {},
  }) {
    var blocked = false;
    void visit(fs.Node node) {
      if (blocked || !node.visible || ignoredRoots.contains(node)) return;
      for (final component in node.getComponents<fs.InstancedMeshComponent>()) {
        final mesh = component.instancedMesh;
        if (_transparent(mesh.material)) continue;
        final data = _data(mesh.geometry);
        // Scene exposes no public read-only transform getter. Read live values
        // without mutation; flattening the authored mesh would miss animation.
        // ignore: invalid_use_of_internal_member
        for (final transform in mesh.instances) {
          if (segmentBlocked(
            eye,
            target,
            data.positions,
            indices: data.indices,
            transform: node.globalTransform.multiplied(transform),
            bounds: mesh.geometry.localBounds,
          )) {
            blocked = true;
            return;
          }
        }
      }
      for (final component in node.getComponents<fs.MeshComponent>()) {
        for (final part in component.mesh.primitives) {
          if (!part.visible || _transparent(part.material)) continue;
          final data = _data(part.geometry);
          if (segmentBlocked(
            eye,
            target,
            data.positions,
            indices: data.indices,
            transform: node.globalTransform,
            bounds: part.geometry.localBounds,
          )) {
            blocked = true;
            return;
          }
        }
      }
      for (final child in node.children) {
        visit(child);
      }
    }

    visit(scene.root);
    return !blocked;
  }

  /// Two-sided Möller–Trumbore against a finite segment, in local coordinates.
  /// A target's own surface/floor endpoint is excluded by a small end margin.
  static bool segmentBlocked(
    vm.Vector3 eye,
    vm.Vector3 target,
    Float32List positions, {
    List<int>? indices,
    vm.Matrix4? transform,
    vm.Aabb3? bounds,
  }) {
    if (!eye.storage.every((v) => v.isFinite) ||
        !target.storage.every((v) => v.isFinite) ||
        (transform != null && !transform.storage.every((v) => v.isFinite))) {
      return true;
    }
    final inverse = transform == null
        ? vm.Matrix4.identity()
        : vm.Matrix4.copy(transform);
    if (inverse.invert() == 0) return true;
    final start = inverse.transformed3(eye),
        finish = inverse.transformed3(target);
    final dx = finish.x - start.x,
        dy = finish.y - start.y,
        dz = finish.z - start.z;
    if (bounds != null && !_intersectsBounds(start, finish, bounds)) {
      return false;
    }
    final worldLength = eye.distanceTo(target);
    if (worldLength <= .02) return false;
    final maxT = 1 - math.min(.02 / worldLength, .1);
    final count = indices?.length ?? positions.length ~/ 3;
    for (var n = 0; n + 2 < count; n += 3) {
      final a = (indices?[n] ?? n) * 3, b = (indices?[n + 1] ?? n + 1) * 3;
      final c = (indices?[n + 2] ?? n + 2) * 3;
      final ax = positions[a], ay = positions[a + 1], az = positions[a + 2];
      final e1x = positions[b] - ax,
          e1y = positions[b + 1] - ay,
          e1z = positions[b + 2] - az;
      final e2x = positions[c] - ax,
          e2y = positions[c + 1] - ay,
          e2z = positions[c + 2] - az;
      final px = dy * e2z - dz * e2y,
          py = dz * e2x - dx * e2z,
          pz = dx * e2y - dy * e2x;
      final det = e1x * px + e1y * py + e1z * pz;
      if (det.abs() < 1e-10) continue;
      final tx = start.x - ax, ty = start.y - ay, tz = start.z - az;
      final u = (tx * px + ty * py + tz * pz) / det;
      if (u < 0 || u > 1) continue;
      final qx = ty * e1z - tz * e1y,
          qy = tz * e1x - tx * e1z,
          qz = tx * e1y - ty * e1x;
      final v = (dx * qx + dy * qy + dz * qz) / det;
      if (v < 0 || u + v > 1) continue;
      final t = (e2x * qx + e2y * qy + e2z * qz) / det;
      if (t > .00001 && t < maxT) return true;
    }
    return false;
  }

  static bool _intersectsBounds(vm.Vector3 a, vm.Vector3 b, vm.Aabb3 bounds) {
    var minT = 0.0, maxT = 1.0;
    for (var axis = 0; axis < 3; axis++) {
      final direction = b[axis] - a[axis];
      if (direction.abs() < 1e-12) {
        if (a[axis] < bounds.min[axis] || a[axis] > bounds.max[axis]) {
          return false;
        }
        continue;
      }
      var near = (bounds.min[axis] - a[axis]) / direction;
      var far = (bounds.max[axis] - a[axis]) / direction;
      if (near > far) {
        final swap = near;
        near = far;
        far = swap;
      }
      minT = math.max(minT, near);
      maxT = math.min(maxT, far);
      if (minT > maxT) return false;
    }
    return true;
  }
}
