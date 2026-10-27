import '../../vrlizate_apps_expedition.dart';

/// A view of the existing campaign state, not another quest/progress ledger.
/// Main and side actors share the same renderer and never coexist in a world.
final class VrlzExpeditionTask {
  VrlzExpeditionTask._(this.controller, this.side, this.mission);
  factory VrlzExpeditionTask.current(VrlzExpeditionController controller) =>
      VrlzExpeditionTask._(
        controller,
        controller.focusedSideQuest,
        controller.nextMission,
      );

  final VrlzExpeditionController controller;
  final VrlzExpeditionSideQuest? side;
  final VrlzExpeditionMission? mission;
  bool get isSide => side != null;
  bool get exists => side != null || mission != null;
  String? get id => side?.id ?? mission?.id;
  String? get actorId => side == null ? mission?.id : 'side_${side!.id}';
  String? get title => side?.title ?? mission?.title;
  VrlzExpeditionGiver? get giver => side?.giver ?? mission?.giver;
  VrlzExpeditionObject? get object =>
      side == null ? mission?.object : controller.focusedSideChoice?.object;
  String? get giverWorld => side?.world ?? mission?.world;
  String? get objectWorld =>
      side == null ? mission?.world : controller.focusedSideChoice?.route.last;
  String? get destination =>
      side == null ? mission?.world : controller.sideDestination;
  bool get accepted => side == null
      ? controller.acceptedMissionId == mission?.id && mission != null
      : controller.focusedSideChoice != null;
  bool get collected => side == null
      ? controller.objectiveCollected
      : (controller.focusedSideProgress?.collected ?? false);
  bool showGiver(String world) => giver != null && giverWorld == world;
  bool showObject(String world) =>
      object != null &&
      objectWorld == world &&
      (!isSide ||
          controller.focusedSideProgress?.visitedStops ==
              controller.focusedSideChoice?.route.length);

  bool canTalk(String world, List<double> position) =>
      controller.ready &&
      showGiver(world) &&
      near(position, giver!.position, giver!.radius);
  bool canInteract(String world, List<double> position) => isSide
      ? controller.canInteractSideQuest(side!.id, world, position)
      : mission != null && controller.canInteract(mission!.id, world, position);
  bool interact(String world, List<double> position) => isSide
      ? controller.interactSideQuest(side!.id, world, position)
      : mission != null && controller.interact(mission!.id, world, position);
  bool canReturn(String world, List<double> position) => isSide
      ? controller.canCompleteSideQuest(side!.id, world, position)
      : mission != null && controller.canComplete(mission!.id, world, position);

  static bool near(List<double> position, List<double> target, double radius) {
    if (position.length != 3 || position.any((v) => !v.isFinite)) return false;
    var distance2 = 0.0;
    for (var i = 0; i < 3; i++) {
      final d = position[i] - target[i];
      distance2 += d * d;
    }
    return distance2 <= radius * radius;
  }
}

/// One contextual route access. Its identity changes with focus/route phase so
/// queued gaze hits cannot advance a different choice or later checkpoint.
final class VrlzExpeditionRoute {
  VrlzExpeditionRoute._(this.questId, this.destination, this.name);
  final String questId, destination, name;
  static const position = <double>[8, 1.3, 9];
  static VrlzExpeditionRoute? current(
    VrlzExpeditionController controller,
    String world,
  ) {
    final quest = controller.focusedSideQuest,
        destination = controller.sideDestination;
    if (!controller.ready ||
        quest == null ||
        destination == null ||
        destination == world) {
      return null;
    }
    final progress = controller.focusedSideProgress;
    return VrlzExpeditionRoute._(
      quest.id,
      destination,
      'vrlz_side_route_${quest.id}_${progress?.choiceId ?? 'offer'}_${progress?.visitedStops ?? 0}_${progress?.collected ?? false}_$destination',
    );
  }

  bool canTravel(
    VrlzExpeditionController controller,
    String world,
    List<double> eye,
    String nodeName,
  ) =>
      current(controller, world)?.name == name &&
      nodeName == name &&
      VrlzExpeditionTask.near(eye, position, 3.5);
}

/// A save may finish after navigation or lifecycle has changed. A ticket is
/// checked after every await before opening another world, for both route kinds.
final class VrlzExpeditionTravelGuard {
  const VrlzExpeditionTravelGuard(this.generation, this.navigation);
  final int generation, navigation;
  bool permits({
    required bool mounted,
    required bool active,
    required bool exiting,
    required bool hasError,
    required int currentGeneration,
    required int currentNavigation,
  }) =>
      mounted &&
      active &&
      !exiting &&
      !hasError &&
      generation == currentGeneration &&
      navigation == currentNavigation;
}
