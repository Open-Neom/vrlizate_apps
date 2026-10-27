import 'dart:math' as math;

import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;
import 'package:vrlizate_scene/vrlizate_scene.dart' show VrTextLabel;

import '../../vrlizate_apps_expedition.dart';
import 'vrlz_expedition_actor.dart';
import 'vrlz_world_change_policy.dart';

/// One bounded overlay in the current world. Immutable primitives/materials
/// are shared, labels rasterize only on creation, and no world resources load.
final class VrlzWorldChangeOverlay {
  VrlzWorldChangeOverlay._(this.change)
    : _propPosition = change.prop == null
          ? null
          : vm.Vector3.array(change.prop!.position),
      _accessPosition = change.access == null
          ? null
          : vm.Vector3.array(change.access!.position);
  final VrlzExpeditionWorldChange change;
  final vm.Vector3? _propPosition, _accessPosition;
  final root = fs.Node()..raycastable = false;
  fs.Node? propRoot, accessRoot;
  VrlzExpeditionActor? reaction;
  bool _disposed = false, _showReaction = true;

  static final _shapes = <VrlzWorldPropShape, fs.Geometry>{};
  static final _materials =
      <VrlzWorldPropSurface, fs.PhysicallyBasedMaterial>{};
  static fs.Geometry _shape(VrlzWorldPropShape shape) => _shapes.putIfAbsent(
    shape,
    () => switch (shape) {
      VrlzWorldPropShape.box => fs.CuboidGeometry(vm.Vector3.all(1)),
      VrlzWorldPropShape.round => fs.IcosphereGeometry(
        radius: .5,
        subdivisions: 1,
      ),
      VrlzWorldPropShape.cylinder => fs.CylinderGeometry(
        bottomRadius: .5,
        topRadius: .5,
        height: 1,
        radialSegments: 8,
      ),
      VrlzWorldPropShape.cone => fs.CylinderGeometry(
        bottomRadius: .5,
        topRadius: 0,
        height: 1,
        radialSegments: 8,
      ),
    },
  );
  static fs.PhysicallyBasedMaterial _material(VrlzWorldPropSurface surface) =>
      _materials.putIfAbsent(
        surface,
        () => fs.PhysicallyBasedMaterial()
          ..baseColorFactor = switch (surface) {
            VrlzWorldPropSurface.structure => vm.Vector4(.22, .28, .31, 1),
            VrlzWorldPropSurface.accent => vm.Vector4(.58, .34, .15, 1),
            VrlzWorldPropSurface.organic => vm.Vector4(.12, .43, .27, 1),
            VrlzWorldPropSurface.light => vm.Vector4(.18, .73, .78, 1),
          }
          ..emissiveFactor = surface == VrlzWorldPropSurface.light
              ? vm.Vector4(.05, .25, .28, 0)
              : vm.Vector4.zero()
          ..roughnessFactor = .78,
      );

  static void _piece(fs.Node root, String name, VrlzWorldPropPiece piece) {
    root.add(
      fs.Node(
          name: name,
          mesh: fs.Mesh(_shape(piece.shape), _material(piece.surface)),
        )
        ..position = vm.Vector3.array(piece.center)
        ..scale = vm.Vector3.array(piece.size)
        ..shadowCastingMode = fs.ShadowCastingMode.off,
    );
  }

  static Future<VrlzWorldChangeOverlay?> create(
    VrlzExpeditionWorldChange change, {
    required vm.Vector3 eye,
    required bool Function() isCurrent,
  }) async {
    final result = VrlzWorldChangeOverlay._(change);
    Future<bool> label(
      fs.Node parent,
      String value,
      vm.Vector3 center,
      double height,
      double width, {
      int lines = 3,
    }) async {
      final text = await VrTextLabel.create(
        value,
        center: center,
        height: height,
        fontSize: 58,
        maxLines: lines,
        maxWidthPx: 1400,
      );
      if (!isCurrent()) return false;
      final relativeEye = eye - parent.position;
      text.faceCamera(relativeEye);
      final scale = math.min(1.0, width / text.worldWidth);
      text.node.localTransform.scaleByDouble(scale, scale, scale, 1);
      parent.add(
        text.node
          ..raycastable = false
          ..shadowCastingMode = fs.ShadowCastingMode.off,
      );
      return true;
    }

    try {
      final prop = change.prop;
      if (prop != null) {
        final node = fs.Node()
          ..raycastable = false
          ..position = vm.Vector3.array(prop.position);
        result.propRoot = node;
        result.root.add(node);
        for (final piece in VrlzWorldPropPlan.pieces(prop.kind)) {
          _piece(node, VrlzWorldChangePolicy.propName(change.id), piece);
        }
        if (!await label(
          node,
          '${prop.label}\nEXAMINAR · A / MIRADA',
          vm.Vector3(0, prop.kind == 'shelter' ? 2.55 : 2.12, 0),
          .19,
          1.8,
          lines: 2,
        )) {
          result.dispose();
          return null;
        }
      }
      final access = change.access;
      if (access != null) {
        final node = fs.Node()
          ..raycastable = false
          ..position = vm.Vector3.array(access.position);
        result.accessRoot = node;
        result.root.add(node);
        const box = VrlzWorldPropShape.box,
            structure = VrlzWorldPropSurface.structure,
            light = VrlzWorldPropSurface.light;
        for (final piece in const [
          VrlzWorldPropPiece(box, [-.55, 0, 0], [.1, 2.6, .2], structure),
          VrlzWorldPropPiece(box, [.55, 0, 0], [.1, 2.6, .2], structure),
          VrlzWorldPropPiece(box, [0, 1.23, 0], [1.2, .14, .2], light),
          VrlzWorldPropPiece(box, [0, 0, .04], [.9, .36, .12], light),
        ]) {
          _piece(node, VrlzWorldChangePolicy.accessName(change.id), piece);
        }
        if (!await label(
          node,
          '${access.label}\nVIAJAR · A / MIRADA',
          vm.Vector3(0, .55, .15),
          .20,
          1.9,
        )) {
          result.dispose();
          return null;
        }
      }
      if (change.reaction != null) {
        final actor = await VrlzExpeditionActor.createEntities(
          id: VrlzWorldChangePolicy.actorId(change.id),
          giver: change.reaction!,
          showObject: false,
          collected: false,
          accepted: false,
          eye: eye,
          isCurrent: isCurrent,
        );
        if (!isCurrent() || actor == null) {
          actor?.dispose();
          result.dispose();
          return null;
        }
        result.reaction = actor;
        result.root.add(actor.root);
      }
      if (!isCurrent()) {
        result.dispose();
        return null;
      }
      return result;
    } catch (_) {
      result.dispose();
      rethrow;
    }
  }

  void setReactionVisible(bool visible) {
    _showReaction = visible;
    reaction?.root.visible = visible;
  }

  void tick(double dt, vm.Vector3 eye) {
    if (_disposed || !dt.isFinite || dt <= 0) return;
    if (_propPosition != null) {
      propRoot?.visible = _propPosition.distanceToSquared(eye) <= 40 * 40;
    }
    if (_accessPosition != null) {
      accessRoot?.visible = _accessPosition.distanceToSquared(eye) <= 48 * 48;
    }
    if (_showReaction) reaction?.tick(dt, eye);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    root.detach();
    reaction?.dispose();
    reaction = null;
    root.removeAll();
    propRoot = accessRoot = null;
  }
}
