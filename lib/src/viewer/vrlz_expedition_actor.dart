import 'dart:math' as math;

import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;
import 'package:vrlizate_avatar/vrlizate_avatar.dart';
import 'package:vrlizate_scene/vrlizate_scene.dart'
    show VrAvatarNode, VrAvatarDetail, VrTextLabel;

import '../../vrlizate_apps_expedition.dart';

/// One retained mission giver/object pair. Avatars use the existing procedural
/// batches, materials, presets and cached shapes; no remote assets or AI.
final class VrlzExpeditionActor {
  VrlzExpeditionActor._(
    this.root,
    this.avatar,
    this.giverPlacement,
    this.position,
  );
  final fs.Node root;
  final fs.Node? giverPlacement;
  final VrAvatarNode? avatar;
  final vm.Vector3 position;
  double _elapsed = 0;
  bool _disposed = false;

  // Scene nodes do not own/dispose immutable Geometry. Share these bounded
  // process-lifetime shapes across mission state rebuilds, like avatar shapes.
  static final _objectShapes = <String, fs.Geometry>{};
  static final _badgeShape = fs.CuboidGeometry(vm.Vector3(.42, .25, .08));

  static fs.Geometry _objectShape(String kind) => _objectShapes.putIfAbsent(
    kind,
    () => switch (kind) {
      'collect' => fs.IcosphereGeometry(radius: .24, subdivisions: 1),
      'examine' => fs.CuboidGeometry(vm.Vector3(.55, .12, .40)),
      _ => fs.CylinderGeometry(
        bottomRadius: .24,
        topRadius: .24,
        height: .40,
        radialSegments: 12,
      ),
    },
  );

  static String giverName(String missionId) =>
      'vrlz_expedition_giver_$missionId';
  static String objectName(String missionId) =>
      'vrlz_expedition_object_$missionId';

  static VrAvatarAppearance appearance(String species) {
    final kind = switch (species) {
      'human' => VrAvatarSpecies.human,
      'robot' || 'droid' || 'courier' => VrAvatarSpecies.robot,
      'fox' => VrAvatarSpecies.fox,
      'axolotl' => VrAvatarSpecies.axolotl,
      'sprout' => VrAvatarSpecies.sprout,
      _ => VrAvatarSpecies.orb,
    };
    return VrAvatarPresetCatalog.defaultForSpecies(
      kind,
    ).copyWith(heightMeters: 1.6);
  }

  static Future<VrlzExpeditionActor?> create(
    VrlzExpeditionMission mission, {
    required bool collected,
    required bool accepted,
    required vm.Vector3 eye,
    required bool Function() isCurrent,
  }) => createEntities(
    id: mission.id,
    giver: mission.giver!,
    object: mission.object,
    collected: collected,
    accepted: accepted,
    eye: eye,
    isCurrent: isCurrent,
  );

  static Future<VrlzExpeditionActor?> createEntities({
    required String id,
    required VrlzExpeditionGiver giver,
    VrlzExpeditionObject? object,
    bool showGiver = true,
    bool showObject = true,
    required bool collected,
    required bool accepted,
    required vm.Vector3 eye,
    required bool Function() isCurrent,
  }) async {
    final position = vm.Vector3.array(giver.position);
    final avatar = showGiver
        ? VrAvatarNode(appearance: appearance(giver.species))
        : null;
    final placement = avatar == null
        ? null
        : (fs.Node()
            ..raycastable = false
            ..localTransform = (vm.Matrix4.translation(position)
              ..rotateY(math.atan2(eye.x - position.x, eye.z - position.z)))
            ..add(avatar.root));
    final root = fs.Node()..raycastable = false;
    if (placement != null) root.add(placement);
    final result = VrlzExpeditionActor._(root, avatar, placement, position);
    try {
      if (placement != null) {
        final badge = fs.PhysicallyBasedMaterial()
          ..baseColorFactor = vm.Vector4(.08, .55, .42, 1)
          ..roughnessFactor = .8;
        // A visible clipboard is the selection surface; the avatar itself uses
        // InstancedMesh, which Scene does not yet raycast natively.
        placement.add(
          fs.Node(name: giverName(id), mesh: fs.Mesh(_badgeShape, badge))
            ..position = vm.Vector3(0, 1.02, .36),
        );
        final label = await VrTextLabel.create(
          '${giver.name}\nHABLAR · A / MIRADA',
          center: vm.Vector3(0, 1.95, .08),
          height: .20,
          fontSize: 58,
          maxLines: 2,
          maxWidthPx: 1200,
        );
        if (!isCurrent()) {
          result.dispose();
          return null;
        }
        _limit(label, 1.6);
        placement.add(label.node..raycastable = false);
      }
      if (showObject && object != null) {
        final target = fs.Node()
          ..raycastable = false
          ..position = vm.Vector3.array(object.position);
        final material = fs.PhysicallyBasedMaterial()
          ..baseColorFactor = collected
              ? vm.Vector4(.17, .45, .29, 1)
              : accepted
              ? vm.Vector4(.16, .67, .70, 1)
              : vm.Vector4(.34, .37, .40, 1)
          ..emissiveFactor = collected
              ? vm.Vector4(.02, .10, .04, 0)
              : vm.Vector4(.02, .12, .15, 0)
          ..roughnessFactor = .65;
        final shape = _objectShape(object.kind);
        target.add(
          fs.Node(name: objectName(id), mesh: fs.Mesh(shape, material))
            ..raycastable = !collected
            ..scale = collected && object.kind == 'collect'
                ? vm.Vector3.all(.25)
                : vm.Vector3.all(1),
        );
        final verb = collected
            ? 'REGISTRADO · VUELVE AL PERSONAJE'
            : !accepted
            ? 'HABLA PRIMERO CON EL PERSONAJE'
            : switch (object.kind) {
                'collect' => 'RECOGER · A',
                'examine' => 'EXAMINAR · A',
                _ => 'ACTIVAR · A',
              };
        final objectLabel = await VrTextLabel.create(
          '${object.label}\n$verb',
          center: vm.Vector3(0, .55, 0),
          height: .18,
          maxLines: 3,
          fontSize: 58,
          maxWidthPx: 1200,
        );
        if (!isCurrent()) {
          result.dispose();
          return null;
        }
        objectLabel.faceCamera(eye - vm.Vector3.array(object.position));
        _limit(objectLabel, 1.65);
        target.add(objectLabel.node..raycastable = false);
        root.add(target);
      }
      _withoutShadows(root);
      return result;
    } catch (_) {
      result.dispose();
      rethrow;
    }
  }

  void tick(double dt, vm.Vector3 eye) {
    if (_disposed || !dt.isFinite || dt <= 0) return;
    final avatar = this.avatar, giverPlacement = this.giverPlacement;
    if (avatar == null || giverPlacement == null) return;
    final distance2 = position.distanceToSquared(eye);
    giverPlacement.visible = distance2 <= 36 * 36;
    final detail =
        distance2 < (avatar.detail == VrAvatarDetail.near ? 12 * 12 : 9 * 9)
        ? VrAvatarDetail.near
        : VrAvatarDetail.far;
    if (detail != avatar.detail) {
      avatar.setDetail(detail);
      _withoutShadows(avatar.root);
    }
    if (!giverPlacement.visible || detail == VrAvatarDetail.far) return;
    _elapsed += dt.clamp(0.0, .1);
    if (_elapsed < 1 / 15) return;
    giverPlacement.localTransform = vm.Matrix4.translation(position)
      ..rotateY(math.atan2(eye.x - position.x, eye.z - position.z));
    avatar.tick(_elapsed);
    _elapsed = 0;
  }

  static void _limit(VrTextLabel label, double width) {
    final scale = math.min(1.0, width / label.worldWidth);
    label.node.localTransform.scaleByDouble(scale, scale, scale, 1);
  }

  static void _withoutShadows(fs.Node node) {
    node.shadowCastingMode = fs.ShadowCastingMode.off;
    for (final child in node.children) {
      _withoutShadows(child);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    root.detach();
    avatar?.dispose();
    root.removeAll();
  }
}
