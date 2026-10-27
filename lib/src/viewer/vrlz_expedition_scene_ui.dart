import 'dart:math' as math;

import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;
import 'package:vrlizate_scene/vrlizate_scene.dart'
    show VrButton3D, VrTextLabel;

import '../../vrlizate_apps.dart';
import 'vrlz_expedition_presenter.dart';
import 'vrlz_expedition_task.dart';

/// Bounded spatial UI made with the existing widgets. No downloaded meshes,
/// per-frame rasterization or hidden offscreen worlds are created.
/// The legacy expedition UI adds at most19 mesh primitives /128 triangles:
/// totem3/26, objective2/14 and passport14/88. This small host UI is separate
/// from the unchanged resident-world profile and existing portal/HOME controls.
/// Giver missions replace the objective with one retained avatar/object pair;
/// their bounded LOD geometry is accounted separately by VrAvatarPlan.
abstract final class VrlzExpeditionSceneUi {
  static const openName = 'vrlz_passport_open';
  static const missionName = 'vrlz_expedition_mission';
  static String objectiveName(String missionId) => '${missionName}_$missionId';
  static const buttonPrefix = 'vrlz_passport_';
  static const previousName = '${buttonPrefix}previous';
  static const nextName = '${buttonPrefix}next';
  static const travelName = '${buttonPrefix}travel';
  static const closeName = '${buttonPrefix}close';
  static const saveName = '${buttonPrefix}save';
  static const acceptName = '${buttonPrefix}accept';
  static const returnName = '${buttonPrefix}return';

  static Future<fs.Node?> route(
    VrlzExpeditionRoute route,
    String title, {
    required vm.Vector3 eye,
    required bool Function() isCurrent,
  }) async {
    final position = vm.Vector3.array(VrlzExpeditionRoute.position);
    final root = fs.Node()..raycastable = false;
    root.addAll(
      VrButton3D(
        name: route.name,
        label: 'Continuar ruta',
        center: position,
        width: .65,
        height: .42,
        color: vm.Vector4(.38, .20, .50, 1),
      ).nodes,
    );
    final label = await VrTextLabel.create(
      'RUTA ALTERNATIVA\n$title\nVIAJAR · A / MIRADA',
      center: position + vm.Vector3(0, .5, 0),
      height: .20,
      fontSize: 58,
      maxLines: 3,
      maxWidthPx: 1200,
    );
    if (!isCurrent()) return null;
    label.faceCamera(eye);
    _limitWidth(label, 1.8);
    root.add(label.node..raycastable = false);
    return _withoutShadows(root);
  }

  static Future<fs.Node?> totem(
    vm.Vector3 position, {
    required vm.Vector3 eye,
    required bool Function() isCurrent,
  }) async {
    final root = fs.Node()..raycastable = false;
    final material = fs.PhysicallyBasedMaterial()
      ..baseColorFactor = vm.Vector4(.035, .24, .28, 1)
      ..roughnessFactor = .75
      ..emissiveFactor = vm.Vector4(.03, .14, .16, 0);
    root.add(
      fs.Node(
          mesh: fs.Mesh(fs.CuboidGeometry(vm.Vector3(.24, .8, .24)), material),
        )
        ..position = position + vm.Vector3(0, -.55, 0)
        ..raycastable = false,
    );
    final button = VrButton3D(
      name: openName,
      label: 'Pasaporte',
      center: position,
      width: .55,
      height: .30,
      color: vm.Vector4(.05, .50, .58, 1),
    );
    root.addAll(button.nodes);
    final label = await VrTextLabel.create(
      'PASAPORTE · X / A',
      center: position + vm.Vector3(0, .28, .12),
      height: .105,
      fontSize: 56,
      maxWidthPx: 900,
    );
    if (!isCurrent()) return null;
    label.faceCamera(eye);
    _limitWidth(label, 1.05);
    root.add(label.node..raycastable = false);
    return _withoutShadows(root);
  }

  static Future<fs.Node?> objective(
    VrlzExpeditionMission mission, {
    required vm.Vector3 eye,
    required bool Function() isCurrent,
  }) async {
    final root = fs.Node()..raycastable = false;
    final position = vm.Vector3.array(mission.position);
    final button = VrButton3D(
      name: objectiveName(mission.id),
      label: mission.title,
      center: position,
      width: .5,
      height: .5,
      color: vm.Vector4(.08, .67, .45, 1),
    );
    root.addAll(button.nodes);
    final label = await VrTextLabel.create(
      '${mission.title}\nACÉRCATE · A / MIRADA',
      center: position + vm.Vector3(0, .55, 0),
      height: .22,
      fontSize: 60,
      maxLines: 3,
      maxWidthPx: 1200,
    );
    if (!isCurrent()) return null;
    label.faceCamera(eye);
    _limitWidth(label, 1.65);
    root.add(label.node..raycastable = false);
    return _withoutShadows(root);
  }

  static Future<fs.Node?> passport({
    required VrlzPassportPresentation presentation,
    required int page,
    required String currentWorld,
    required vm.Vector3 eye,
    required vm.Vector3 forward,
    required bool Function() isCurrent,
    void Function(VrButton3D button)? onButton,
  }) async {
    final horizontal = vm.Vector3(forward.x, 0, forward.z);
    if (horizontal.length2 < .001) horizontal.setValues(0, 0, -1);
    horizontal.normalize();
    final center = eye + horizontal * 2.25;
    center.y = eye.y + .05;
    final yaw = math.atan2(eye.x - center.x, eye.z - center.z);
    final root = fs.Node()
      ..raycastable = false
      ..localTransform = (vm.Matrix4.translation(center)..rotateY(yaw));
    final material = fs.PhysicallyBasedMaterial()
      ..baseColorFactor = vm.Vector4(.018, .045, .062, 1)
      ..roughnessFactor = .9
      ..emissiveFactor = vm.Vector4(.012, .025, .035, 0);
    root.add(
      fs.Node(
        mesh: fs.Mesh(fs.CuboidGeometry(vm.Vector3(2.85, 2.24, .08)), material),
      )..raycastable = false,
    );

    Future<bool> text(
      String value,
      double y,
      double height, {
      int maxLines = 1,
      double width = 2.55,
      double fontSize = 58,
    }) async {
      final label = await VrTextLabel.create(
        value,
        center: vm.Vector3(0, y, .065),
        height: height,
        fontSize: fontSize,
        maxWidthPx: 1700,
        maxLines: maxLines,
      );
      if (!isCurrent()) return false;
      _limitWidth(label, width);
      root.add(label.node..raycastable = false);
      return true;
    }

    final shown = presentation.pages[page];
    if (!await text(shown.title, .78, .16, maxLines: 2)) return null;
    if (!await text(shown.body, .12, .78, maxLines: 9)) return null;
    if (!await text(
      '${page + 1}/${presentation.pages.length} · ${presentation.saveStatus}\nStick / flechas: ← → página · ↑ ↓ botón\nA / Enter: elegir · X / B: cerrar',
      -.44,
      .23,
      maxLines: 4,
      fontSize: 40,
    )) {
      return null;
    }

    Future<bool> button(
      String name,
      String label,
      double x,
      double y, {
      double width = .65,
    }) async {
      final control = VrButton3D(
        name: name,
        label: label,
        center: vm.Vector3(x, y, .11),
        width: width,
        height: .22,
        color: vm.Vector4(.05, .32, .38, 1),
      );
      root.addAll(control.nodes);
      onButton?.call(control);
      final text = await VrTextLabel.create(
        label,
        center: vm.Vector3(x, y, .18),
        height: .085,
        maxWidthPx: 850,
        fontSize: 54,
        maxLines: 2,
      );
      if (!isCurrent()) return false;
      _limitWidth(text, width - .05);
      root.add(text.node..raycastable = false);
      return true;
    }

    if (!await button(previousName, 'Anterior', -1.02, -.72, width: .62)) {
      return null;
    }
    if (!await button(nextName, 'Siguiente', -.34, -.72, width: .62)) {
      return null;
    }
    if (!await button(closeName, 'Cerrar', 1.02, -.72, width: .62)) return null;
    final nextWorld = presentation.nextWorld;
    if (presentation.giverAction != VrlzGiverAction.none) {
      final accepting = presentation.giverAction == VrlzGiverAction.accept;
      if (!await button(
        accepting ? acceptName : returnName,
        accepting ? 'Aceptar misión' : 'Entregar',
        .34,
        -.72,
        width: .62,
      )) {
        return null;
      }
    } else if (nextWorld != null) {
      if (!await button(
        travelName,
        nextWorld == currentWorld ? 'Ver objetivo' : 'Ir al objetivo',
        .34,
        -.72,
        width: .62,
      )) {
        return null;
      }
    }
    if (shown.actions.isEmpty) {
      if (!await button(saveName, 'Guardar progreso', 0, -.94, width: 1.20)) {
        return null;
      }
    } else {
      for (var i = 0; i < shown.actions.length; i++) {
        final action = shown.actions[i];
        final x = shown.actions.length == 1 ? 0.0 : (i == 0 ? -.68 : .68);
        if (!await button(action.name, action.label, x, -.94, width: 1.20)) {
          return null;
        }
      }
    }
    return _withoutShadows(root);
  }

  static fs.Node _withoutShadows(fs.Node root) {
    void visit(fs.Node node) {
      node.shadowCastingMode = fs.ShadowCastingMode.off;
      for (final child in node.children) {
        visit(child);
      }
    }

    visit(root);
    return root;
  }

  static void _limitWidth(VrTextLabel label, double width) {
    final scale = math.min(1.0, width / label.worldWidth);
    label.node.localTransform.scaleByDouble(scale, scale, scale, 1);
    label.node.shadowCastingMode = fs.ShadowCastingMode.off;
  }
}
