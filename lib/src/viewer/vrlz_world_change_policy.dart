import '../../vrlizate_apps_expedition.dart';
import 'vrlz_expedition_task.dart';

/// Ephemeral admission for one asynchronous overlay build. A rejected build
/// releases its own cache entry, never the entry of a newer world/lifecycle.
final class VrlzWorldChangeBuildState {
  String? _id;
  int _epoch = 0;
  String? get id => _id;
  int begin(String id) {
    _id = id;
    return ++_epoch;
  }

  void invalidate() {
    _id = null;
    _epoch++;
  }

  bool matches(int epoch, String id) => epoch == _epoch && id == _id;
  bool discard(int epoch) {
    if (epoch != _epoch) return false;
    _id = null;
    _epoch++;
    return true;
  }
}

/// Selection is always resolved against the current delivered history, not a
/// retained render node. Inspection never calls a mission/progress action.
abstract final class VrlzWorldChangePolicy {
  static String propName(String id) => 'vrlz_change_prop_$id';
  static String accessName(String id) => 'vrlz_change_access_$id';
  static String actorId(String id) => 'world_change_$id';
  static bool canInspect(
    VrlzExpeditionController controller,
    String world,
    List<double> eye,
    String name,
  ) {
    final change = controller.worldChange(world),
        prop = controller.worldChange(world)?.prop;
    return change != null &&
        prop != null &&
        name == propName(change.id) &&
        VrlzExpeditionTask.near(eye, prop.position, prop.radius);
  }

  static bool canTalk(
    VrlzExpeditionController controller,
    String world,
    List<double> eye,
  ) {
    final reaction = controller.worldChange(world)?.reaction;
    return reaction != null &&
        !VrlzExpeditionTask.current(controller).showGiver(world) &&
        VrlzExpeditionTask.near(eye, reaction.position, reaction.radius);
  }

  static VrlzExpeditionGiver? taskReaction(
    VrlzExpeditionController controller,
    String world,
  ) {
    final task = VrlzExpeditionTask.current(controller),
        reaction = controller.worldChange(world)?.reaction;
    return task.showGiver(world) && task.giver?.id == reaction?.id
        ? reaction
        : null;
  }
}

/// Revalidated after a possibly slow save. Change, destination, centre and
/// proximity must still match; lifecycle/generation use the existing guard.
final class VrlzWorldChangeTravelTicket {
  VrlzWorldChangeTravelTicket._(
    this.changeId,
    this.world,
    this.destination,
    this.position,
  );
  final String changeId, world, destination;
  final List<double> position;
  static VrlzWorldChangeTravelTicket? capture(
    VrlzExpeditionController controller,
    String world,
    List<double> eye,
    String name,
  ) {
    final change = controller.worldChange(world),
        access = controller.worldChange(world)?.access;
    if (change == null ||
        access == null ||
        name != VrlzWorldChangePolicy.accessName(change.id) ||
        !VrlzExpeditionTask.near(eye, access.position, access.radius)) {
      return null;
    }
    return VrlzWorldChangeTravelTicket._(
      change.id,
      world,
      access.destination,
      List.unmodifiable(access.position),
    );
  }

  bool permits(
    VrlzExpeditionController controller,
    String currentWorld,
    List<double> eye,
  ) {
    final change = controller.worldChange(currentWorld),
        access = change?.access;
    return currentWorld == world &&
        change?.id == changeId &&
        access != null &&
        access.destination == destination &&
        access.position[0] == position[0] &&
        access.position[1] == position[1] &&
        access.position[2] == position[2] &&
        VrlzExpeditionTask.near(eye, access.position, access.radius);
  }
}

enum VrlzWorldPropShape { box, round, cylinder, cone }

enum VrlzWorldPropSurface { structure, accent, organic, light }

final class VrlzWorldPropPiece {
  const VrlzWorldPropPiece(this.shape, this.center, this.size, this.surface);
  final VrlzWorldPropShape shape;
  final List<double> center, size;
  final VrlzWorldPropSurface surface;
  int get triangles => switch (shape) {
    VrlzWorldPropShape.box => 12,
    VrlzWorldPropShape.round => 80,
    VrlzWorldPropShape.cylinder => 32,
    VrlzWorldPropShape.cone => 16,
  };
}

/// Pure authoring plan for four small, recognizable interventions. All parts
/// fit X±.8/Z±.6 relative to feet, Y0..2 (shelter0..2.4), independent of world meshes.
abstract final class VrlzWorldPropPlan {
  static List<VrlzWorldPropPiece> pieces(String kind) {
    const box = VrlzWorldPropShape.box,
        round = VrlzWorldPropShape.round,
        cylinder = VrlzWorldPropShape.cylinder,
        cone = VrlzWorldPropShape.cone;
    const structure = VrlzWorldPropSurface.structure,
        accent = VrlzWorldPropSurface.accent,
        organic = VrlzWorldPropSurface.organic,
        light = VrlzWorldPropSurface.light;
    return switch (kind) {
      'planter' => const [
        VrlzWorldPropPiece(box, [0, .2, 0], [1.2, .4, .75], structure),
        VrlzWorldPropPiece(box, [0, .43, 0], [1.05, .06, .6], accent),
        VrlzWorldPropPiece(cylinder, [0, .83, 0], [.12, .75, .12], organic),
        VrlzWorldPropPiece(round, [-.23, 1.1, 0], [.55, .5, .48], organic),
        VrlzWorldPropPiece(round, [.23, 1.1, 0], [.55, .5, .48], organic),
        VrlzWorldPropPiece(round, [0, 1.38, 0], [.50, .46, .45], organic),
      ],
      'archive' => const [
        VrlzWorldPropPiece(box, [0, .75, -.34], [1.1, 1.5, .12], structure),
        VrlzWorldPropPiece(box, [-.55, .75, 0], [.1, 1.5, .8], structure),
        VrlzWorldPropPiece(box, [.55, .75, 0], [.1, 1.5, .8], structure),
        VrlzWorldPropPiece(box, [0, .05, 0], [1, .1, .8], structure),
        VrlzWorldPropPiece(box, [0, .75, 0], [1, .08, .8], structure),
        VrlzWorldPropPiece(box, [0, 1.46, 0], [1, .08, .8], structure),
        VrlzWorldPropPiece(box, [-.31, 1.03, .03], [.2, .45, .5], accent),
        VrlzWorldPropPiece(box, [0, 1.03, .03], [.2, .45, .5], light),
        VrlzWorldPropPiece(box, [.31, 1.03, .03], [.2, .45, .5], accent),
        VrlzWorldPropPiece(box, [0, .83, .35], [1.1, .08, .45], accent),
        VrlzWorldPropPiece(box, [-.45, .38, .53], [.06, .76, .06], structure),
        VrlzWorldPropPiece(box, [.45, .38, .53], [.06, .76, .06], structure),
      ],
      'beacon' => const [
        VrlzWorldPropPiece(box, [0, .09, 0], [.75, .18, .75], structure),
        VrlzWorldPropPiece(cylinder, [0, .78, 0], [.18, 1.2, .18], structure),
        VrlzWorldPropPiece(box, [0, 1.5, 0], [.5, .45, .5], light),
        VrlzWorldPropPiece(cone, [0, 1.85, 0], [.65, .25, .65], accent),
      ],
      'shelter' => const [
        VrlzWorldPropPiece(box, [0, .06, 0], [1.4, .12, 1.2], structure),
        VrlzWorldPropPiece(box, [-.6, 1.18, -.5], [.1, 2.12, .1], accent),
        VrlzWorldPropPiece(box, [.6, 1.18, -.5], [.1, 2.12, .1], accent),
        VrlzWorldPropPiece(box, [-.6, 1.18, .5], [.1, 2.12, .1], accent),
        VrlzWorldPropPiece(box, [.6, 1.18, .5], [.1, 2.12, .1], accent),
        VrlzWorldPropPiece(box, [0, 2.30, 0], [1.4, .16, 1.2], structure),
        VrlzWorldPropPiece(box, [0, .65, -.55], [1.2, .8, .08], organic),
        VrlzWorldPropPiece(box, [0, .84, 0], [.9, .08, .45], accent),
        VrlzWorldPropPiece(box, [0, .48, 0], [.12, .72, .12], structure),
      ],
      _ => throw ArgumentError.value(kind, 'kind', 'Unknown world prop'),
    };
  }
}
