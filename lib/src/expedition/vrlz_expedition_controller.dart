import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'vrlz_expedition_definition.dart';
import 'vrlz_expedition_persistence.dart';

/// Linear, proximity-gated local progress. A synchronous true means a change
/// was accepted in memory; only a successful [flush] confirms durable storage.
/// World content/texture hashes are deliberately absent from saved progress.
final class VrlzExpeditionController extends ChangeNotifier {
  VrlzExpeditionController({required this.definition, required this.store});

  static const maxSnapshotBytes = VrlzExpeditionDefinition.maxSnapshotBytes;
  final VrlzExpeditionDefinition definition;
  final VrlzExpeditionPersistence store;
  final _visits = <String, DateTime>{};
  final _completed = <String, DateTime>{};
  final _side = <String, VrlzExpeditionSideProgress>{};
  String? _focusedSideQuestId;
  bool _ready = false, _disposed = false, _scheduled = false;
  int _changed = 0, _saved = 0;
  String? _saveError;
  String? _acceptedMissionId;
  bool _objectiveCollected = false;
  DateTime _lastTimestamp = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  Future<void>? _restoring;
  Future<bool>? _flushing;

  bool get ready => _ready && !_disposed;
  String? get saveError => _saveError;
  Map<String, DateTime> get visitedWorlds => Map.unmodifiable(_visits);
  Map<String, DateTime> get completedMissions => Map.unmodifiable(_completed);
  String? get acceptedMissionId => _acceptedMissionId;
  bool get objectiveCollected => _objectiveCollected;
  Map<String, VrlzExpeditionSideProgress> get sideProgress =>
      Map.unmodifiable(_side);
  String? get focusedSideQuestId => _focusedSideQuestId;
  VrlzExpeditionSideQuest? _sideQuest(String? id) {
    for (final quest in definition.sideQuests) {
      if (quest.id == id) return quest;
    }
    return null;
  }

  VrlzExpeditionChoice? _choice(VrlzExpeditionSideQuest quest, String? id) {
    for (final choice in quest.choices) {
      if (choice.id == id) return choice;
    }
    return null;
  }

  bool _requirementsMet(
    List<VrlzExpeditionStoryRequirement> requirements,
    Map<String, VrlzExpeditionSideProgress> history,
  ) => requirements.every((requirement) {
    final source = history[requirement.questId];
    return source?.completedAt != null &&
        requirement.choiceIds.contains(source!.choiceId);
  });

  /// Unlock is derived from delivered stories, never a separate stored flag.
  bool isSideQuestUnlocked(VrlzExpeditionSideQuest quest) {
    final canonical = _sideQuest(quest.id);
    return ready &&
        canonical != null &&
        _completed.containsKey(canonical.afterMissionId) &&
        _requirementsMet(canonical.requires, _side);
  }

  /// Also works for completed history. Only canonical authored data is used.
  String sideQuestDialogue(VrlzExpeditionSideQuest quest) {
    final canonical = _sideQuest(quest.id);
    if (canonical == null) throw ArgumentError('Unknown side quest.');
    if (ready) {
      for (final variant in canonical.dialogueVariants) {
        if (_requirementsMet(variant.requires, _side)) return variant.dialogue;
      }
    }
    return canonical.giver.dialogue;
  }

  /// A single canonical intervention, derived from delivered branch history.
  VrlzExpeditionWorldChange? worldChange(String world) {
    if (!ready || !definition.worlds.containsKey(world)) return null;
    for (final change in definition.worldChanges) {
      if (change.world == world && _requirementsMet(change.requires, _side)) {
        return change;
      }
    }
    return null;
  }

  VrlzExpeditionSideQuest? get focusedSideQuest =>
      _sideQuest(_focusedSideQuestId);
  VrlzExpeditionSideProgress? get focusedSideProgress =>
      _side[_focusedSideQuestId];
  VrlzExpeditionChoice? get focusedSideChoice {
    final quest = focusedSideQuest;
    return quest == null ? null : _choice(quest, focusedSideProgress?.choiceId);
  }

  String? get pendingSideQuestId {
    for (final entry in _side.entries) {
      if (entry.value.completedAt == null) return entry.key;
    }
    return null;
  }

  List<VrlzExpeditionSideQuest> get availableSideQuests => List.unmodifiable([
    if (ready)
      for (final quest in definition.sideQuests)
        if (isSideQuestUnlocked(quest) && _side[quest.id]?.completedAt == null)
          quest,
  ]);
  String? get sideDestination {
    final quest = focusedSideQuest,
        choice = focusedSideChoice,
        progress = focusedSideProgress;
    if (quest == null) return null;
    if (choice == null || progress == null || progress.collected) {
      return quest.world;
    }
    return progress.visitedStops < choice.route.length
        ? choice.route[progress.visitedStops]
        : choice.route.last;
  }

  /// Rewards are derived from completed IDs, never a second mutable ledger.
  Set<String> get rewardIds => Set.unmodifiable({
    for (final mission in definition.missions)
      if (_completed.containsKey(mission.id) && mission.rewardId != null)
        mission.rewardId!,
  });
  VrlzExpeditionMission? get nextMission =>
      ready && _completed.length < definition.missions.length
      ? definition.missions[_completed.length]
      : null;

  /// Idempotent after success. Failed/corrupt reads remain retryable and never
  /// turn into an empty save that overwrites the original data.
  Future<void> restore() {
    if (_disposed) return Future.error(StateError('Expedition is disposed.'));
    if (_ready) return Future.value();
    final active = _restoring;
    if (active != null) return active;
    final done = Completer<void>();
    _restoring = done.future;
    unawaited(_restore(done));
    return done.future;
  }

  Future<void> _restore(Completer<void> done) async {
    try {
      final bytes = await store.read(definition.id);
      if (_disposed) throw StateError('Expedition is disposed.');
      if (bytes != null) {
        final state = _decode(Uint8List.fromList(bytes));
        _visits.addAll(state.visits);
        _completed.addAll(state.completed);
        _acceptedMissionId = state.acceptedMissionId;
        _objectiveCollected = state.objectiveCollected;
        _side.addAll(state.side);
        _focusedSideQuestId = state.focusedSideQuestId;
        for (final date in [
          ..._visits.values,
          ..._completed.values,
          for (final progress in _side.values)
            if (progress.completedAt != null) progress.completedAt!,
        ]) {
          if (date.isAfter(_lastTimestamp)) _lastTimestamp = date;
        }
      }
      _ready = true;
      _saveError = null;
      _notify();
      done.complete();
    } catch (error, stack) {
      if (!_disposed) {
        _saveError = 'No se pudo cargar el progreso de la expedición.';
        _notify();
      }
      done.completeError(error, stack);
    } finally {
      _restoring = null;
    }
  }

  /// First stamps and post-choice ordered route arrivals are persisted together.
  /// A previously stamped world can still advance a newly chosen route.
  bool visit(String world) {
    if (!ready || !definition.worlds.containsKey(world)) {
      return false;
    }
    var changed = false;
    if (!_visits.containsKey(world)) {
      _visits[world] = _now();
      changed = true;
    }
    final id = pendingSideQuestId, quest = _sideQuest(pendingSideQuestId);
    if (id != null && quest != null) {
      final progress = _side[id]!,
          choice = _choice(quest, _side[id]!.choiceId)!;
      if (!progress.collected &&
          progress.visitedStops < choice.route.length &&
          choice.route[progress.visitedStops] == world) {
        _side[id] = VrlzExpeditionSideProgress(
          choiceId: progress.choiceId,
          visitedStops: progress.visitedStops + 1,
          collected: false,
        );
        changed = true;
      }
    }
    if (!changed) return false;
    _dirty();
    return true;
  }

  bool focusSideQuest(String? id) {
    if (!ready || id == _focusedSideQuestId) return false;
    if (id != null &&
        (pendingSideQuestId != null && pendingSideQuestId != id ||
            !availableSideQuests.any((quest) => quest.id == id))) {
      return false;
    }
    _focusedSideQuestId = id;
    _dirty();
    return true;
  }

  bool canChooseSideQuest(
    String id,
    String choiceId,
    String world,
    List<double> position,
  ) {
    final quest = _sideQuest(id);
    return ready &&
        quest != null &&
        quest.world == world &&
        _visits.containsKey(world) &&
        isSideQuestUnlocked(quest) &&
        !_side.containsKey(id) &&
        pendingSideQuestId == null &&
        _choice(quest, choiceId) != null &&
        _near(position, quest.giver.position, quest.giver.radius);
  }

  bool chooseSideQuest(
    String id,
    String choiceId,
    String world,
    List<double> position,
  ) {
    if (!canChooseSideQuest(id, choiceId, world, position)) return false;
    _side[id] = VrlzExpeditionSideProgress(
      choiceId: choiceId,
      visitedStops: 0,
      collected: false,
    );
    _focusedSideQuestId = id;
    _dirty();
    return true;
  }

  bool canInteractSideQuest(String id, String world, List<double> position) {
    final quest = _sideQuest(id), progress = _side[id];
    if (!ready ||
        quest == null ||
        progress == null ||
        progress.collected ||
        progress.completedAt != null) {
      return false;
    }
    final choice = _choice(quest, progress.choiceId)!;
    return progress.visitedStops == choice.route.length &&
        world == choice.route.last &&
        _visits.containsKey(world) &&
        _near(position, choice.object.position, choice.object.radius);
  }

  bool interactSideQuest(String id, String world, List<double> position) {
    if (!canInteractSideQuest(id, world, position)) return false;
    final progress = _side[id]!;
    _side[id] = VrlzExpeditionSideProgress(
      choiceId: progress.choiceId,
      visitedStops: progress.visitedStops,
      collected: true,
    );
    _dirty();
    return true;
  }

  bool canCompleteSideQuest(String id, String world, List<double> position) {
    final quest = _sideQuest(id), progress = _side[id];
    return ready &&
        quest != null &&
        progress != null &&
        progress.collected &&
        progress.completedAt == null &&
        quest.world == world &&
        _visits.containsKey(world) &&
        _near(position, quest.giver.position, quest.giver.radius);
  }

  bool completeSideQuest(String id, String world, List<double> position) {
    if (!canCompleteSideQuest(id, world, position)) return false;
    final progress = _side[id]!;
    _side[id] = VrlzExpeditionSideProgress(
      choiceId: progress.choiceId,
      visitedStops: progress.visitedStops,
      collected: true,
      completedAt: _now(),
    );
    _focusedSideQuestId = null;
    _dirty();
    return true;
  }

  VrlzExpeditionMission? _current(String missionId, String world) {
    final mission = nextMission;
    if (mission == null ||
        mission.id != missionId ||
        mission.world != world ||
        !_visits.containsKey(world)) {
      return null;
    }
    return mission;
  }

  bool _near(List<double> position, List<double> target, double radius) {
    if (position.length != 3 ||
        position.any((v) => !v.isFinite || v.abs() > 1e6)) {
      return false;
    }
    var distance2 = 0.0;
    for (var axis = 0; axis < 3; axis++) {
      final delta = position[axis] - target[axis];
      distance2 += delta * delta;
    }
    return distance2 <= radius * radius;
  }

  bool canAccept(String missionId, String world, List<double> position) {
    final giver = _current(missionId, world)?.giver;
    return giver != null &&
        _acceptedMissionId == null &&
        _near(position, giver.position, giver.radius);
  }

  /// Explicit conversation action. Merely loading a world grants nothing.
  bool accept(String missionId, String world, List<double> position) {
    if (!canAccept(missionId, world, position)) return false;
    _acceptedMissionId = missionId;
    _objectiveCollected = false;
    _dirty();
    return true;
  }

  bool canInteract(String missionId, String world, List<double> position) {
    final object = _current(missionId, world)?.object;
    return object != null &&
        _acceptedMissionId == missionId &&
        !_objectiveCollected &&
        _near(position, object.position, object.radius);
  }

  /// Explicit pickup action after accepting the current objective.
  bool interact(String missionId, String world, List<double> position) {
    if (!canInteract(missionId, world, position)) return false;
    _objectiveCollected = true;
    _dirty();
    return true;
  }

  bool canComplete(String missionId, String world, List<double> position) {
    final mission = _current(missionId, world);
    if (mission == null) return false;
    final giver = mission.giver;
    if (giver != null) {
      return _acceptedMissionId == missionId &&
          _objectiveCollected &&
          _near(position, giver.position, giver.radius);
    }
    return _near(position, mission.position, mission.radius);
  }

  /// Known, ordered, visited and nearby objectives alone produce discoveries.
  /// Repeating a completed objective is an idempotent false, without a write.
  bool complete(String missionId, String world, List<double> position) {
    if (!canComplete(missionId, world, position)) return false;
    _completed[missionId] = _now();
    _acceptedMissionId = null;
    _objectiveCollected = false;
    _dirty();
    return true;
  }

  DateTime _now() {
    final now = DateTime.now().toUtc();
    // Nondecreasing timestamps survive a corrected system clock without
    // overflowing a previously accepted timestamp at the supported year limit.
    if (!now.isBefore(_lastTimestamp)) _lastTimestamp = now;
    return _lastTimestamp;
  }

  void _dirty() {
    _changed++;
    _notify();
    if (_scheduled) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      if (_ready && _saved < _changed) unawaited(flush());
    });
  }

  /// Serializes writes, coalesces updates arriving during a write, and retries
  /// dirty state on the next explicit call after a storage error. No timer or
  /// frame callback is used. Accepted pending state can still drain on dispose.
  Future<bool> flush() {
    if (!_ready) return Future.value(false);
    final active = _flushing;
    if (active != null) return active;
    final done = Completer<bool>();
    _flushing = done.future;
    unawaited(_drain(done));
    return done.future;
  }

  Future<void> _drain(Completer<bool> done) async {
    var success = false;
    try {
      while (true) {
        if (_saved >= _changed) {
          if (_saveError != null) {
            _saveError = null;
            _notify();
            continue;
          }
          success = true;
          break;
        }
        final writing = _changed;
        final bytes = _encode();
        await store.write(definition.id, bytes);
        _saved = writing;
      }
    } catch (_) {
      _saveError = 'No se pudo guardar el progreso de la expedición.';
      _notify();
    } finally {
      _flushing = null;
      done.complete(success);
    }
  }

  Uint8List _encode() {
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'schema': 1,
          'id': definition.id,
          'experienceId': definition.experienceId,
          'revision': definition.revision,
          'visitedWorlds': {
            for (final entry in _visits.entries)
              entry.key: entry.value.toIso8601String(),
          },
          'completedMissions': {
            for (final entry in _completed.entries)
              entry.key: entry.value.toIso8601String(),
          },
          if (_acceptedMissionId != null)
            'pendingMission': {
              'missionId': _acceptedMissionId,
              'stage': _objectiveCollected ? 'collected' : 'accepted',
            },
          if (_side.isNotEmpty)
            'sideQuests': {
              for (final entry in _side.entries)
                entry.key: entry.value.toJson(),
            },
          if (_focusedSideQuestId != null)
            'focusedSideQuestId': _focusedSideQuestId,
        }),
      ),
    );
    if (bytes.length > maxSnapshotBytes) {
      throw StateError('Expedition snapshot exceeds 32 KiB.');
    }
    return bytes;
  }

  ({
    Map<String, DateTime> visits,
    Map<String, DateTime> completed,
    String? acceptedMissionId,
    bool objectiveCollected,
    Map<String, VrlzExpeditionSideProgress> side,
    String? focusedSideQuestId,
  })
  _decode(Uint8List bytes) {
    Never invalid() => throw const FormatException(
      'Invalid or incompatible expedition progress.',
    );
    if (bytes.isEmpty || bytes.length > maxSnapshotBytes) invalid();
    final raw = jsonDecode(utf8.decode(bytes));
    if (raw is! Map<String, dynamic>) invalid();
    const fields = {
      'schema',
      'id',
      'experienceId',
      'revision',
      'visitedWorlds',
      'completedMissions',
    };
    if (!fields.every(raw.containsKey) ||
        !raw.keys.every(
          (key) =>
              fields.contains(key) ||
              const {
                'pendingMission',
                'sideQuests',
                'focusedSideQuestId',
              }.contains(key),
        ) ||
        raw['schema'] is! int ||
        raw['schema'] != 1 ||
        raw['id'] != definition.id ||
        raw['experienceId'] != definition.experienceId ||
        raw['revision'] is! int ||
        raw['revision'] != definition.revision) {
      invalid();
    }
    final visits = raw['visitedWorlds'], completed = raw['completedMissions'];
    if (visits is! Map<String, dynamic> ||
        visits.length > definition.worlds.length ||
        completed is! Map<String, dynamic> ||
        completed.length > definition.missions.length) {
      invalid();
    }
    DateTime timestamp(Object? value) {
      if (value is! String || value.length > 32 || !value.endsWith('Z')) {
        invalid();
      }
      final date = DateTime.tryParse(value);
      if (date == null ||
          !date.isUtc ||
          date.year < 1 ||
          date.year > 9999 ||
          date.toIso8601String() != value) {
        invalid();
      }
      return date;
    }

    final knownVisits = <String, DateTime>{};
    for (final entry in visits.entries) {
      if (!definition.worlds.containsKey(entry.key)) invalid();
      knownVisits[entry.key] = timestamp(entry.value);
    }
    final knownCompleted = <String, DateTime>{};
    DateTime? previous;
    for (var index = 0; index < completed.length; index++) {
      final mission = definition.missions[index];
      if (!completed.containsKey(mission.id)) invalid();
      final date = timestamp(completed[mission.id]);
      final visit = knownVisits[mission.world];
      if (visit == null ||
          date.isBefore(visit) ||
          (previous != null && date.isBefore(previous))) {
        invalid();
      }
      knownCompleted[mission.id] = date;
      previous = date;
    }
    String? acceptedMissionId;
    var objectiveCollected = false;
    if (raw.containsKey('pendingMission')) {
      final pending = raw['pendingMission'];
      if (pending is! Map<String, dynamic> ||
          pending.length != 2 ||
          !pending.containsKey('missionId') ||
          !pending.containsKey('stage') ||
          knownCompleted.length >= definition.missions.length) {
        invalid();
      }
      final next = definition.missions[knownCompleted.length];
      if (pending['missionId'] != next.id ||
          next.giver == null ||
          next.object == null ||
          !knownVisits.containsKey(next.world) ||
          (pending['stage'] != 'accepted' && pending['stage'] != 'collected')) {
        invalid();
      }
      acceptedMissionId = next.id;
      objectiveCollected = pending['stage'] == 'collected';
    }
    final knownSide = <String, VrlzExpeditionSideProgress>{};
    String? pendingSide;
    if (raw.containsKey('sideQuests')) {
      final side = raw['sideQuests'];
      if (side is! Map<String, dynamic> ||
          side.isEmpty ||
          side.length > definition.sideQuests.length) {
        invalid();
      }
      for (final entry in side.entries) {
        final quest = _sideQuest(entry.key), value = entry.value;
        if (quest == null ||
            !knownCompleted.containsKey(quest.afterMissionId) ||
            !knownVisits.containsKey(quest.world) ||
            value is! Map<String, dynamic> ||
            !const {
              'choiceId',
              'visitedStops',
              'collected',
            }.every(value.containsKey) ||
            !value.keys.every(
              (key) => const {
                'choiceId',
                'visitedStops',
                'collected',
                'completedAt',
              }.contains(key),
            ) ||
            value['choiceId'] is! String ||
            value['visitedStops'] is! int ||
            value['collected'] is! bool) {
          invalid();
        }
        final choice = _choice(quest, value['choiceId'] as String);
        final stops = value['visitedStops'] as int,
            collected = value['collected'] as bool;
        if (choice == null ||
            stops < 0 ||
            stops > choice.route.length ||
            collected && stops != choice.route.length ||
            choice.route
                .take(stops)
                .any((world) => !knownVisits.containsKey(world))) {
          invalid();
        }
        final completedAt = value.containsKey('completedAt')
            ? timestamp(value['completedAt'])
            : null;
        if (completedAt != null) {
          if (!collected ||
              completedAt.isBefore(knownCompleted[quest.afterMissionId]!) ||
              completedAt.isBefore(knownVisits[quest.world]!) ||
              choice.route.any(
                (world) => completedAt.isBefore(knownVisits[world]!),
              )) {
            invalid();
          }
        } else {
          if (pendingSide != null) invalid();
          pendingSide = quest.id;
        }
        knownSide[quest.id] = VrlzExpeditionSideProgress(
          choiceId: choice.id,
          visitedStops: stops,
          collected: collected,
          completedAt: completedAt,
        );
      }
    }
    // Decode all records before resolving dependencies, so map iteration order
    // cannot authorize an incomplete prerequisite or reject a valid history.
    for (final entry in knownSide.entries) {
      final quest = _sideQuest(entry.key)!, progress = entry.value;
      if (!_requirementsMet(quest.requires, knownSide)) invalid();
      final date = progress.completedAt;
      if (date != null &&
          quest.requires.any(
            (requirement) =>
                date.isBefore(knownSide[requirement.questId]!.completedAt!),
          )) {
        invalid();
      }
    }
    String? focusedSideQuestId;
    if (raw.containsKey('focusedSideQuestId')) {
      final id = raw['focusedSideQuestId'];
      if (id is! String) invalid();
      final quest = _sideQuest(id);
      if (quest == null ||
          !knownCompleted.containsKey(quest.afterMissionId) ||
          !_requirementsMet(quest.requires, knownSide) ||
          knownSide[id]?.completedAt != null ||
          pendingSide != null && pendingSide != id) {
        invalid();
      }
      focusedSideQuestId = id;
    }
    return (
      visits: knownVisits,
      completed: knownCompleted,
      acceptedMissionId: acceptedMissionId,
      objectiveCollected: objectiveCollected,
      side: knownSide,
      focusedSideQuestId: focusedSideQuestId,
    );
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_ready && _saved < _changed) unawaited(flush());
    super.dispose();
  }
}
