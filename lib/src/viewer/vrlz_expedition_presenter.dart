import 'package:vrlizate_scene/vrlizate_scene.dart'
    show
        VrGamepadButton,
        VrGamepadStick,
        VrInputEvent,
        VrInputSource,
        VrInputType;
import 'package:vrlizate_avatar/vrlizate_avatar.dart'
    show VrAvatarCosmeticCatalog;

import '../../vrlizate_apps_expedition.dart';
import 'vrlz_expedition_task.dart';

enum VrlzPassportActionKind { focusSide, focusMain, chooseSide, returnSide }

final class VrlzPassportAction {
  const VrlzPassportAction(
    this.kind,
    this.label, {
    this.questId,
    this.choiceId,
  });
  final VrlzPassportActionKind kind;
  final String label;
  final String? questId, choiceId;
  String get name =>
      'vrlz_passport_side_${kind.name}_${questId ?? 'main'}_${choiceId ?? 'none'}';

  bool canRun(
    VrlzExpeditionController controller,
    String world,
    List<double> position, {
    required bool dialogue,
  }) {
    if (!controller.ready) return false;
    return switch (kind) {
      VrlzPassportActionKind.focusMain => controller.focusedSideQuestId != null,
      VrlzPassportActionKind.focusSide =>
        controller.focusedSideQuestId != questId &&
            controller.availableSideQuests.any((q) => q.id == questId) &&
            (controller.pendingSideQuestId == null ||
                controller.pendingSideQuestId == questId),
      VrlzPassportActionKind.chooseSide =>
        dialogue &&
            controller.focusedSideQuestId == questId &&
            controller.canChooseSideQuest(questId!, choiceId!, world, position),
      VrlzPassportActionKind.returnSide =>
        dialogue &&
            controller.focusedSideQuestId == questId &&
            controller.canCompleteSideQuest(questId!, world, position),
    };
  }
}

/// Small immutable pages; the renderer rasterizes only the displayed page.
final class VrlzPassportPage {
  const VrlzPassportPage(
    this.title,
    this.body, {
    this.missionId,
    this.sideQuestId,
    this.actions = const [],
  });
  final String title, body;
  final String? missionId, sideQuestId;
  final List<VrlzPassportAction> actions;
}

enum VrlzGiverAction { none, accept, returnObject }

/// UI stage is derived from the persisted controller, never a second quest log.
abstract final class VrlzExpeditionTaskPresentation {
  static bool canTalk(
    VrlzExpeditionController expedition,
    String world,
    List<double> position,
  ) {
    final mission = expedition.nextMission,
        giver = expedition.nextMission?.giver;
    if (!expedition.ready ||
        mission == null ||
        giver == null ||
        mission.world != world ||
        position.length != 3 ||
        position.any((v) => !v.isFinite)) {
      return false;
    }
    var distance2 = 0.0;
    for (var i = 0; i < 3; i++) {
      final d = position[i] - giver.position[i];
      distance2 += d * d;
    }
    return distance2 <= giver.radius * giver.radius;
  }

  static String instruction(VrlzExpeditionController expedition) {
    final mission = expedition.nextMission;
    if (mission == null) return 'Expedición completada.';
    if (mission.giver == null) return mission.instruction;
    if (expedition.acceptedMissionId != mission.id) {
      return 'Habla con ${mission.giver!.name} y acepta la misión.\n${mission.instruction}';
    }
    if (expedition.objectiveCollected) {
      return 'Vuelve con ${mission.giver!.name} para entregar el objetivo.';
    }
    final verb = switch (mission.object!.kind) {
      'collect' => 'Recoge',
      'examine' => 'Examina',
      _ => 'Activa',
    };
    return '$verb ${mission.object!.label}.\n${mission.instruction}';
  }

  static VrlzGiverAction giverAction(VrlzExpeditionController expedition) {
    final mission = expedition.nextMission;
    if (mission?.giver == null) return VrlzGiverAction.none;
    if (expedition.acceptedMissionId != mission!.id) {
      return VrlzGiverAction.accept;
    }
    return expedition.objectiveCollected
        ? VrlzGiverAction.returnObject
        : VrlzGiverAction.none;
  }
}

final class VrlzPassportPresentation {
  VrlzPassportPresentation(
    VrlzExpeditionController expedition, {
    bool dialogue = false,
    List<VrlzPassportPage> prefixPages = const [],
  }) {
    final definition = expedition.definition;
    final next = expedition.nextMission;
    final visits = expedition.visitedWorlds;
    final completed = expedition.completedMissions;
    final error = expedition.saveError;
    final task = VrlzExpeditionTask.current(expedition);
    nextWorld = task.destination;
    nextTitle = task.title;
    progress =
        'Sellos ${visits.length}/${definition.worlds.length}'
        ' · Misiones ${completed.length}/${definition.missions.length}'
        '${definition.sideQuests.isEmpty ? '' : ' · Historias completadas: ${expedition.sideProgress.values.where((p) => p.completedAt != null).length} · Disponibles: ${expedition.availableSideQuests.length}'}';
    final result = <VrlzPassportPage>[...prefixPages];
    giverAction = dialogue && !task.isSide
        ? VrlzExpeditionTaskPresentation.giverAction(expedition)
        : VrlzGiverAction.none;
    if (dialogue && !task.isSide && next?.giver != null) {
      final text =
          '${next!.giver!.dialogue}\n${VrlzExpeditionTaskPresentation.instruction(expedition)}';
      for (final body in _chunks(text, 360)) {
        result.add(
          VrlzPassportPage('${next.giver!.name} · ${next.title}', body),
        );
      }
    }
    if (task.isSide) result.addAll(_sidePages(expedition, dialogue: dialogue));
    final objective = next == null
        ? '$progress\n${definition.sideQuests.isEmpty ? 'Expedición completada. Todos los descubrimientos están en este pasaporte.' : 'Campaña principal completada. Consulta las historias disponibles y las consecuencias de tus decisiones en este pasaporte.'}'
        : '$progress\n${definition.worlds[next.world]}\n${next.title}\n${VrlzExpeditionTaskPresentation.instruction(expedition)}';
    final introduction = error == null
        ? objective
        : 'Guardado pendiente: el progreso sigue en memoria.\n$objective';
    for (final body in _chunks(introduction, 360)) {
      result.add(VrlzPassportPage('Pasaporte · ${definition.title}', body));
    }
    if (!task.isSide) result.addAll(_sidePages(expedition));
    final worlds = definition.worlds.entries.toList();
    for (var at = 0; at < worlds.length; at += 6) {
      final end = (at + 6).clamp(0, worlds.length);
      final lines = [
        for (final world in worlds.sublist(at, end))
          '${visits.containsKey(world.key) ? '✓' : '○'} ${world.value}',
      ].join('\n');
      for (final body in _chunks(lines, 360)) {
        result.add(VrlzPassportPage('Sellos de lugares', body));
      }
    }
    var discoveries = 0;
    for (final mission in definition.missions) {
      if (!completed.containsKey(mission.id)) continue;
      discoveries++;
      for (final body in _chunks(
        'Descubrimiento registrado.\n${definition.worlds[mission.world]}\n${mission.discovery}'
        '${mission.rewardId == null ? '' : '\nRecompensa: ${VrAvatarCosmeticCatalog.byId(mission.rewardId!)?.title ?? 'Reconocimiento de expedición'}'}',
        360,
      )) {
        result.add(
          VrlzPassportPage(
            'Descubrimiento · ${mission.title}',
            body,
            missionId: mission.id,
          ),
        );
      }
    }
    if (discoveries == 0) {
      result.add(
        const VrlzPassportPage(
          'Descubrimientos',
          'Habla con el personaje de tu siguiente misión o acércate a su marcador y selecciónalo con A o con la mirada. '
              'Cada descubrimiento quedará guardado aquí.',
        ),
      );
    }
    final activeChanges = <String>[
      for (final world in definition.worlds.entries)
        if (expedition.worldChange(world.key) case final change?)
          '${world.value}: ${change.prop?.label ?? 'Cambio registrado'}'
              '${change.access == null ? '' : ' → ${definition.worlds[change.access!.destination] ?? change.access!.destination}'}',
    ];
    for (var at = 0; at < activeChanges.length; at += 4) {
      final end = (at + 4).clamp(0, activeChanges.length);
      for (final body in _chunks(
        activeChanges.sublist(at, end).join('\n'),
        360,
      )) {
        result.add(VrlzPassportPage('Consecuencias · Mundos', body));
      }
    }
    if (error != null) {
      result.add(
        VrlzPassportPage(
          'Guardado pendiente',
          'El progreso sigue en memoria. Reintenta guardar antes de salir.\n$error',
        ),
      );
    }
    pages = List.unmodifiable(result);
    saveStatus = error == null
        ? 'Progreso registrado · guardado local automático'
        : 'Guardado pendiente · el progreso sigue en memoria';
  }

  late final List<VrlzPassportPage> pages;
  late final String progress;
  late final String saveStatus;
  late final String? nextWorld, nextTitle;
  late final VrlzGiverAction giverAction;

  int discoveryPage(String missionId) =>
      pages.indexWhere((page) => page.missionId == missionId);

  int sideQuestPage(String questId) =>
      pages.indexWhere((page) => page.sideQuestId == questId);

  /// Read-only physical inspections share the existing spatial panel. No
  /// selection, completion or progress action is encoded by these pages.
  static List<VrlzPassportPage> inspection(String title, String description) =>
      List.unmodifiable(
        _chunks(description, 360).map((body) => VrlzPassportPage(title, body)),
      );

  static Iterable<VrlzPassportPage> _sidePages(
    VrlzExpeditionController expedition, {
    bool dialogue = false,
  }) sync* {
    final focused = expedition.focusedSideQuest;
    final choice = expedition.focusedSideChoice;
    final progress = expedition.focusedSideProgress;
    String place(String alias) => expedition.definition.worlds[alias] ?? alias;
    if (focused != null) {
      final destination = expedition.sideDestination;
      final stage = choice == null
          ? 'Habla con ${focused.giver.name} para elegir una de dos rutas. No se ha elegido ninguna.'
          : progress!.collected
          ? 'Regresa con ${focused.giver.name} a ${place(focused.world)} y entrega el objetivo.'
          : progress.visitedStops < choice.route.length
          ? 'Viaja a ${place(destination!)}. Paradas ${progress.visitedStops}/${choice.route.length}.'
          : 'Busca ${choice.object.label} en ${place(choice.route.last)} y ${switch (choice.object.kind) {
              'collect' => 'recógelo',
              'examine' => 'examínalo',
              _ => 'actívalo',
            }}.';
      final returning = dialogue && progress?.collected == true;
      final focusActions = <VrlzPassportAction>[
        if (returning)
          VrlzPassportAction(
            VrlzPassportActionKind.returnSide,
            'Entregar',
            questId: focused.id,
          ),
        const VrlzPassportAction(
          VrlzPassportActionKind.focusMain,
          'Volver a principal',
        ),
      ];
      final story =
          '${focused.giver.name}: ${expedition.sideQuestDialogue(focused)}\n'
          '${choice == null ? '' : 'Decisión: ${choice.label}\n${choice.dialogue}\n'}$stage'
          '${dialogue && choice == null ? '\nLa decisión quedará registrada en este pasaporte. Avanza para comparar las dos rutas antes de aceptar.' : ''}';
      for (final body in _chunks(story, 360)) {
        yield VrlzPassportPage(
          'Secundaria · ${focused.title}',
          body,
          sideQuestId: focused.id,
          actions: List.unmodifiable(focusActions),
        );
      }
      if (dialogue && choice == null) {
        final options = <VrlzPassportAction>[
          for (var i = 0; i < focused.choices.length; i++)
            VrlzPassportAction(
              VrlzPassportActionKind.chooseSide,
              'Aceptar ruta ${i + 1}',
              questId: focused.id,
              choiceId: focused.choices[i].id,
            ),
        ];
        final description = [
          for (var i = 0; i < focused.choices.length; i++)
            '${i + 1}. ${focused.choices[i].label}\nRuta: ${focused.choices[i].route.map(place).join(' → ')} → ${place(focused.world)}\n${focused.choices[i].dialogue}',
        ].join('\n\n');
        for (final body in _chunks(description, 360)) {
          yield VrlzPassportPage(
            'Elige una ruta · ${focused.title}',
            body,
            sideQuestId: focused.id,
            actions: List.unmodifiable(options),
          );
        }
      }
    }
    for (final quest in expedition.availableSideQuests) {
      if (quest.id == focused?.id) continue;
      final saved = expedition.sideProgress[quest.id];
      final blocked =
          expedition.pendingSideQuestId != null &&
          expedition.pendingSideQuestId != quest.id;
      final text =
          '${place(quest.world)} · ${quest.giver.name}\n'
          '${blocked
              ? 'Termina la secundaria pendiente antes de seguir otra. La misión principal sigue disponible.'
              : saved == null
              ? 'Dos decisiones posibles. Sigue esta secundaria y habla con el personaje para elegir.'
              : 'Decisión guardada. Retoma la ruta donde la dejaste.'}';
      for (final body in _chunks(text, 360)) {
        yield VrlzPassportPage(
          'Secundaria · ${quest.title}',
          body,
          sideQuestId: quest.id,
          actions: blocked
              ? const []
              : [
                  VrlzPassportAction(
                    VrlzPassportActionKind.focusSide,
                    saved == null ? 'Seguir secundaria' : 'Retomar secundaria',
                    questId: quest.id,
                  ),
                ],
        );
      }
    }
    bool canFocusContinuation(VrlzExpeditionSideQuest chapter) =>
        expedition.focusedSideQuestId != chapter.id &&
        expedition.availableSideQuests.any((q) => q.id == chapter.id) &&
        (expedition.pendingSideQuestId == null ||
            expedition.pendingSideQuestId == chapter.id);
    for (final quest in expedition.definition.sideQuests) {
      final saved = expedition.sideProgress[quest.id];
      if (saved == null) continue;
      final chosen = quest.choices.firstWhere((c) => c.id == saved.choiceId);
      // Only reveal chapters unlocked by the delivered history. Mutually
      // exclusive/blocked chapter names and dialogue never enter UI pages.
      final continuations = saved.completedAt == null
          ? const <VrlzExpeditionSideQuest>[]
          : expedition.definition.sideQuests
                .where(
                  (chapter) =>
                      expedition.isSideQuestUnlocked(chapter) &&
                      chapter.requires.any(
                        (condition) => condition.questId == quest.id,
                      ),
                )
                .toList();
      final consequences = continuations.isEmpty
          ? ''
          : '\nHistorias que habilita esta decisión:\n${[for (var i = 0; i < continuations.length; i++) '${i + 1}. ${continuations[i].title}${expedition.sideProgress[continuations[i].id]?.completedAt == null ? '' : ' (completada)'}'].join('\n')}';
      final actions = <VrlzPassportAction>[
        for (var i = 0; i < continuations.length && i < 2; i++)
          if (canFocusContinuation(continuations[i]))
            VrlzPassportAction(
              VrlzPassportActionKind.focusSide,
              'Seguir historia ${i + 1}',
              questId: continuations[i].id,
            ),
      ];
      final text =
          '${saved.completedAt == null ? 'Historia en curso · paradas ${saved.visitedStops}/${chosen.route.length}' : 'Historia completada. Entrega registrada.$consequences'}\n'
          'Decisión guardada: ${chosen.label}\n${chosen.dialogue}\n'
          'Ruta: ${chosen.route.map(place).join(' → ')} → ${place(quest.world)}\n'
          '${saved.completedAt == null ? '' : chosen.discovery}';
      for (final body in _chunks(text, 360)) {
        yield VrlzPassportPage(
          'Historia · ${quest.title}',
          body,
          sideQuestId: quest.id,
          actions: List.unmodifiable(actions),
        );
      }
      for (var at = 2; at < continuations.length; at += 2) {
        final group = continuations.skip(at).take(2).toList();
        for (final body in _chunks(
          [
            for (var i = 0; i < group.length; i++)
              '${at + i + 1}. ${group[i].title}${expedition.sideProgress[group[i].id]?.completedAt == null ? '' : ' (completada)'}',
          ].join('\n'),
          360,
        )) {
          yield VrlzPassportPage(
            'Continúa · ${quest.title}',
            body,
            sideQuestId: quest.id,
            actions: List.unmodifiable([
              for (var i = 0; i < group.length; i++)
                if (canFocusContinuation(group[i]))
                  VrlzPassportAction(
                    VrlzPassportActionKind.focusSide,
                    'Seguir historia ${at + i + 1}',
                    questId: group[i].id,
                  ),
            ]),
          );
        }
      }
    }
  }

  static Iterable<String> _chunks(String text, int length) sync* {
    var remaining = text;
    while (remaining.length > length) {
      var cut = remaining.lastIndexOf(' ', length);
      if (cut < length ~/ 2) cut = length;
      yield remaining.substring(0, cut).trim();
      remaining = remaining.substring(cut).trimLeft();
    }
    if (remaining.isNotEmpty) yield remaining;
  }

  /// Saves may notify to clear an error without changing mission/visit counts.
  static String stamp(VrlzExpeditionController expedition) =>
      '${expedition.ready}|${expedition.visitedWorlds.keys.join(',')}|'
      '${expedition.completedMissions.keys.join(',')}|${expedition.saveError}|'
      '${expedition.acceptedMissionId}|${expedition.objectiveCollected}|'
      '${expedition.focusedSideQuestId}|${expedition.sideProgress.entries.map((e) => '${e.key}:${e.value.choiceId}:${e.value.visitedStops}:${e.value.collected}:${e.value.completedAt}').join(',')}';
}

enum VrlzPassportIntent {
  none,
  open,
  close,
  exit,
  previousPage,
  nextPage,
  previousControl,
  nextControl,
  activateFocused,
  clearFocus,
}

/// Names only, never scene nodes or borrowed controller events. Focus starts
/// with an explicit vertical navigation gesture; A otherwise keeps ray picking.
final class VrlzPassportFocus {
  List<String> _controls = const [];
  String? focused;

  void replace(Iterable<String> controls) {
    _controls = List.unmodifiable(controls);
    focused = null;
  }

  void clear() => focused = null;

  void move(int delta) {
    if (_controls.isEmpty || delta == 0) return;
    final at = focused == null ? -1 : _controls.indexOf(focused!);
    final next = at < 0
        ? (delta > 0 ? 0 : _controls.length - 1)
        : (at + delta).clamp(0, _controls.length - 1);
    focused = _controls[next];
  }
}

/// CPU input policy shared by physical X, the phone's X edge and B/back.
/// Trigger releases clear hold state even while the viewer is paused.
final class VrlzPassportInputPolicy {
  final _heldX = <VrInputSource>{};
  final _heldNavigation = <VrInputSource>{};
  final _pointerPositions = <VrInputSource, (double, double)>{};
  final _awaitingNeutral = <VrInputSource>{};

  void reset({bool requireNeutral = false}) {
    _heldX.clear();
    _heldNavigation.clear();
    _pointerPositions.clear();
    _awaitingNeutral.clear();
    if (requireNeutral) _awaitingNeutral.addAll(VrInputSource.values);
  }

  VrlzPassportIntent handle(
    VrInputEvent event, {
    required bool active,
    required bool loading,
    required bool exiting,
    required bool ready,
    required bool open,
    bool hasFocus = false,
  }) {
    final button = event.data?['button'];
    var pointerChanged = false;
    if (event.type == VrInputType.pointerMove) {
      final data = event.data;
      final x = data?['laserX'] ?? data?['x'];
      final y = data?['laserY'] ?? data?['y'];
      if (!event.active) {
        _pointerPositions.remove(event.source);
      } else if (data?['relativeToHead'] == true &&
          x is num &&
          x.isFinite &&
          y is num &&
          y.isFinite) {
        final position = (x.toDouble(), y.toDouble());
        // The phone repeats retained aim BEFORE every navigation/A packet.
        // Only a changed aim yields focus back to the ray, not that heartbeat.
        pointerChanged = _pointerPositions[event.source] != position;
        _pointerPositions[event.source] = position;
      } else {
        pointerChanged = true;
      }
    }
    VrlzPassportIntent direction = VrlzPassportIntent.none;
    if (event.type == VrInputType.navigate) {
      final data = event.data;
      final stick = data?['stick'];
      if (stick != VrGamepadStick.right && stick != 'right') {
        double axis(Object? v) => v is num && v.isFinite ? v.toDouble() : 0;
        final x = event.active ? axis(data?['stickX'] ?? data?['x']) : 0.0;
        final y = event.active ? axis(data?['stickY'] ?? data?['y']) : 0.0;
        // Hysteresis: a deliberate push selects once; return to center before
        // another page/control. Track while closed to avoid opening on a hold.
        if (x.abs() <= .25 && y.abs() <= .25) {
          _heldNavigation.remove(event.source);
          // The host sends a synthetic release while suspending its route.
          // That release must not re-arm a stick still held on resume.
          if (active && ready && !loading && !exiting && !event.handled) {
            _awaitingNeutral.remove(event.source);
          }
        } else if (!_awaitingNeutral.contains(event.source) &&
            (x.abs() >= .65 || y.abs() >= .65) &&
            _heldNavigation.add(event.source)) {
          direction = x.abs() > y.abs()
              ? (x > 0
                    ? VrlzPassportIntent.nextPage
                    : VrlzPassportIntent.previousPage)
              : (y > 0
                    ? VrlzPassportIntent.previousControl
                    : VrlzPassportIntent.nextControl);
        }
      }
    }
    final physicalX =
        event.type == VrInputType.trigger &&
        (button == VrGamepadButton.x || button == 'x');
    if (physicalX && !event.active) _heldX.remove(event.source);
    if (!active || event.handled || !event.active || exiting) {
      return VrlzPassportIntent.none;
    }
    if (event.type == VrInputType.back || event.type == VrInputType.buttonB) {
      return open ? VrlzPassportIntent.close : VrlzPassportIntent.exit;
    }
    if (!ready || loading) return VrlzPassportIntent.none;
    if (open) {
      if (pointerChanged) {
        return VrlzPassportIntent.clearFocus;
      }
      if (direction != VrlzPassportIntent.none) return direction;
      if (hasFocus &&
          event.type == VrInputType.select &&
          (event.source == VrInputSource.gamepad ||
              event.source == VrInputSource.remotePhone ||
              event.source == VrInputSource.externalPeripheral)) {
        return VrlzPassportIntent.activateFocused;
      }
    }
    if (event.type == VrInputType.buttonX || physicalX) {
      if (physicalX && !_heldX.add(event.source)) {
        return VrlzPassportIntent.none;
      }
      return open ? VrlzPassportIntent.close : VrlzPassportIntent.open;
    }
    return VrlzPassportIntent.none;
  }
}
