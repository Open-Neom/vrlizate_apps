import 'dart:convert';
import 'dart:typed_data';

/// Original character data; [species] is an authored identifier, never code.
final class VrlzExpeditionGiver {
  VrlzExpeditionGiver({
    required String id,
    required String name,
    required String dialogue,
    required String species,
    required List<double> position,
    double radius = 2.5,
  }) : id = _id(id),
       name = _text(name, 160),
       dialogue = _text(dialogue, 1024),
       species = _id(species),
       position = _position(position),
       radius = _radius(radius);

  final String id, name, dialogue, species;
  final List<double> position;
  final double radius;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'dialogue': dialogue,
    'species': species,
    'position': position.toList(),
    'radius': radius,
  };

  factory VrlzExpeditionGiver.fromJson(Map<String, dynamic> json) {
    _keys(json, {'id', 'name', 'dialogue', 'species', 'position', 'radius'});
    try {
      return VrlzExpeditionGiver(
        id: _jsonText(json['id']),
        name: _jsonText(json['name']),
        dialogue: _jsonText(json['dialogue']),
        species: _jsonText(json['species']),
        position: _jsonPosition(json['position']),
        radius: _jsonRadius(json['radius']),
      );
    } on ArgumentError {
      throw const FormatException('Invalid expedition giver.');
    }
  }
}

/// Collectible data. [kind] is a bounded visual identifier, not an asset URI.
final class VrlzExpeditionObject {
  VrlzExpeditionObject({
    required String id,
    required String label,
    required String kind,
    required List<double> position,
    double radius = 2.5,
  }) : id = _id(id),
       label = _text(label, 160),
       kind = _objectKind(kind),
       position = _position(position),
       radius = _radius(radius);

  final String id, label, kind;
  final List<double> position;
  final double radius;

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'kind': kind,
    'position': position.toList(),
    'radius': radius,
  };

  factory VrlzExpeditionObject.fromJson(Map<String, dynamic> json) {
    _keys(json, {'id', 'label', 'kind', 'position', 'radius'});
    try {
      return VrlzExpeditionObject(
        id: _jsonText(json['id']),
        label: _jsonText(json['label']),
        kind: _jsonText(json['kind']),
        position: _jsonPosition(json['position']),
        radius: _jsonRadius(json['radius']),
      );
    } on ArgumentError {
      throw const FormatException('Invalid expedition object.');
    }
  }
}

/// Immutable authored objective. Position is in the named world's local metres.
final class VrlzExpeditionMission {
  VrlzExpeditionMission({
    required String id,
    required String world,
    required String title,
    required String instruction,
    required String discovery,
    required List<double> position,
    double radius = 2.5,
    this.giver,
    this.object,
    String? rewardId,
  }) : id = _id(id),
       world = _id(world),
       title = _text(title, 160),
       instruction = _text(instruction, 1024),
       discovery = _text(discovery, 1024),
       position = _position(position),
       radius = _radius(radius),
       rewardId = rewardId == null ? null : _id(rewardId) {
    if ((giver == null) != (object == null)) {
      throw ArgumentError('Mission giver and object must appear together.');
    }
  }

  final String id, world, title, instruction, discovery;
  final List<double> position;
  final double radius;
  final VrlzExpeditionGiver? giver;
  final VrlzExpeditionObject? object;
  final String? rewardId;

  Map<String, dynamic> toJson() => {
    'id': id,
    'world': world,
    'title': title,
    'instruction': instruction,
    'discovery': discovery,
    'position': position.toList(),
    'radius': radius,
    if (giver != null) 'giver': giver!.toJson(),
    if (object != null) 'object': object!.toJson(),
    if (rewardId != null) 'rewardId': rewardId,
  };

  factory VrlzExpeditionMission.fromJson(Map<String, dynamic> json) {
    _keys(
      json,
      {
        'id',
        'world',
        'title',
        'instruction',
        'discovery',
        'position',
        'radius',
      },
      optional: {'giver', 'object', 'rewardId'},
    );
    try {
      return VrlzExpeditionMission(
        id: _jsonText(json['id']),
        world: _jsonText(json['world']),
        title: _jsonText(json['title']),
        instruction: _jsonText(json['instruction']),
        discovery: _jsonText(json['discovery']),
        position: _jsonPosition(json['position']),
        radius: _jsonRadius(json['radius']),
        giver: json.containsKey('giver')
            ? VrlzExpeditionGiver.fromJson(_jsonMap(json['giver']))
            : null,
        object: json.containsKey('object')
            ? VrlzExpeditionObject.fromJson(_jsonMap(json['object']))
            : null,
        rewardId: json.containsKey('rewardId')
            ? _jsonText(json['rewardId'])
            : null,
      );
    } on ArgumentError {
      throw const FormatException('Invalid expedition mission definition.');
    }
  }
}

/// One authored decision. Its collectible belongs to the last route world.
final class VrlzExpeditionChoice {
  VrlzExpeditionChoice({
    required String id,
    required String label,
    required String dialogue,
    required String discovery,
    required List<String> route,
    required this.object,
  }) : id = _id(id),
       label = _text(label, 160),
       dialogue = _text(dialogue, 1024),
       discovery = _text(discovery, 1024),
       route = List.unmodifiable(route) {
    if (route.isEmpty ||
        route.length > 3 ||
        route.toSet().length != route.length) {
      throw ArgumentError('Use one to three unique route worlds.');
    }
    for (final world in route) {
      _id(world);
    }
  }
  final String id, label, dialogue, discovery;
  final List<String> route;
  final VrlzExpeditionObject object;
  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'dialogue': dialogue,
    'discovery': discovery,
    'route': route.toList(),
    'object': object.toJson(),
  };
  factory VrlzExpeditionChoice.fromJson(Map<String, dynamic> json) {
    _keys(json, {'id', 'label', 'dialogue', 'discovery', 'route', 'object'});
    final route = json['route'];
    if (route is! List || route.length > 3 || route.any((v) => v is! String)) {
      throw const FormatException('Invalid side quest route.');
    }
    try {
      return VrlzExpeditionChoice(
        id: _jsonText(json['id']),
        label: _jsonText(json['label']),
        dialogue: _jsonText(json['dialogue']),
        discovery: _jsonText(json['discovery']),
        route: route.cast<String>(),
        object: VrlzExpeditionObject.fromJson(_jsonMap(json['object'])),
      );
    } on ArgumentError {
      throw const FormatException('Invalid side quest choice.');
    }
  }
}

/// A delivered story with one of the listed choices (OR within this record).
final class VrlzExpeditionStoryRequirement {
  VrlzExpeditionStoryRequirement({
    required String questId,
    required List<String> choiceIds,
  }) : questId = _id(questId),
       choiceIds = List.unmodifiable(choiceIds) {
    if (choiceIds.isEmpty ||
        choiceIds.length > 2 ||
        choiceIds.toSet().length != choiceIds.length) {
      throw ArgumentError('Use one or two distinct story choices.');
    }
    for (final id in choiceIds) {
      _id(id);
    }
  }
  final String questId;
  final List<String> choiceIds;
  Map<String, dynamic> toJson() => {
    'questId': questId,
    'choiceIds': choiceIds.toList(),
  };
  factory VrlzExpeditionStoryRequirement.fromJson(Map<String, dynamic> json) {
    _keys(json, {'questId', 'choiceIds'});
    final choices = json['choiceIds'];
    if (choices is! List ||
        choices.length > 2 ||
        choices.any((id) => id is! String)) {
      throw const FormatException('Invalid story requirement.');
    }
    try {
      return VrlzExpeditionStoryRequirement(
        questId: _jsonText(json['questId']),
        choiceIds: choices.cast<String>(),
      );
    } on ArgumentError {
      throw const FormatException('Invalid story requirement.');
    }
  }
}

/// First matching variant wins; conditions are ANDed and only inspect history.
final class VrlzExpeditionDialogueVariant {
  VrlzExpeditionDialogueVariant({
    required List<VrlzExpeditionStoryRequirement> requires,
    required String dialogue,
  }) : requires = _storyRequirements(requires, nonempty: true),
       dialogue = _text(dialogue, 1024);
  final List<VrlzExpeditionStoryRequirement> requires;
  final String dialogue;
  Map<String, dynamic> toJson() => {
    'requires': [for (final requirement in requires) requirement.toJson()],
    'dialogue': dialogue,
  };
  factory VrlzExpeditionDialogueVariant.fromJson(Map<String, dynamic> json) {
    _keys(json, {'requires', 'dialogue'});
    try {
      return VrlzExpeditionDialogueVariant(
        requires: _jsonStoryRequirements(json['requires']),
        dialogue: _jsonText(json['dialogue']),
      );
    } on ArgumentError {
      throw const FormatException('Invalid dialogue variant.');
    }
  }
}

/// A two-choice story unlocked by a main mission and optional delivered stories.
final class VrlzExpeditionSideQuest {
  VrlzExpeditionSideQuest({
    required String id,
    required String title,
    required String afterMissionId,
    required String world,
    required this.giver,
    required List<VrlzExpeditionChoice> choices,
    List<VrlzExpeditionStoryRequirement> requires = const [],
    List<VrlzExpeditionDialogueVariant> dialogueVariants = const [],
  }) : id = _id(id),
       title = _text(title, 160),
       afterMissionId = _id(afterMissionId),
       world = _id(world),
       choices = List.unmodifiable(choices),
       requires = _storyRequirements(requires),
       dialogueVariants = List.unmodifiable(dialogueVariants) {
    if (choices.length != 2 ||
        choices[0].id == choices[1].id ||
        choices.any((choice) => choice.route.contains(world))) {
      throw ArgumentError(
        'Use two distinct choices whose routes exclude the origin.',
      );
    }
    if (requires.any((requirement) => requirement.questId == id) ||
        dialogueVariants.length > 16) {
      throw ArgumentError('Use bounded dialogue variants and no self unlock.');
    }
  }
  final String id, title, afterMissionId, world;
  final VrlzExpeditionGiver giver;
  final List<VrlzExpeditionChoice> choices;
  final List<VrlzExpeditionStoryRequirement> requires;
  final List<VrlzExpeditionDialogueVariant> dialogueVariants;
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'afterMissionId': afterMissionId,
    'world': world,
    'giver': giver.toJson(),
    'choices': [for (final choice in choices) choice.toJson()],
    if (requires.isNotEmpty)
      'requires': [for (final requirement in requires) requirement.toJson()],
    if (dialogueVariants.isNotEmpty)
      'dialogueVariants': [
        for (final variant in dialogueVariants) variant.toJson(),
      ],
  };
  factory VrlzExpeditionSideQuest.fromJson(Map<String, dynamic> json) {
    _keys(
      json,
      {'id', 'title', 'afterMissionId', 'world', 'giver', 'choices'},
      optional: {'requires', 'dialogueVariants'},
    );
    final choices = json['choices'];
    final variants = json.containsKey('dialogueVariants')
        ? json['dialogueVariants']
        : const [];
    if (choices is! List || choices.length != 2) {
      throw const FormatException('Invalid side quest choices.');
    }
    if (variants is! List || variants.length > 16) {
      throw const FormatException('Invalid dialogue variants.');
    }
    try {
      return VrlzExpeditionSideQuest(
        id: _jsonText(json['id']),
        title: _jsonText(json['title']),
        afterMissionId: _jsonText(json['afterMissionId']),
        world: _jsonText(json['world']),
        giver: VrlzExpeditionGiver.fromJson(_jsonMap(json['giver'])),
        choices: [
          for (final choice in choices)
            VrlzExpeditionChoice.fromJson(_jsonMap(choice)),
        ],
        requires: json.containsKey('requires')
            ? _jsonStoryRequirements(json['requires'])
            : const [],
        dialogueVariants: [
          for (final variant in variants)
            VrlzExpeditionDialogueVariant.fromJson(_jsonMap(variant)),
        ],
      );
    } on ArgumentError {
      throw const FormatException('Invalid side quest.');
    }
  }
}

/// Immutable selected branch and its ordered route progress.
final class VrlzExpeditionSideProgress {
  VrlzExpeditionSideProgress({
    required String choiceId,
    required this.visitedStops,
    required this.collected,
    DateTime? completedAt,
  }) : choiceId = _id(choiceId),
       completedAt = completedAt?.toUtc() {
    if (visitedStops < 0 ||
        visitedStops > 3 ||
        (collected && visitedStops == 0) ||
        (this.completedAt != null &&
            (!collected ||
                this.completedAt!.year < 1 ||
                this.completedAt!.year > 9999))) {
      throw ArgumentError('Invalid side quest progress.');
    }
  }
  final String choiceId;
  final int visitedStops;
  final bool collected;
  final DateTime? completedAt;
  Map<String, dynamic> toJson() => {
    'choiceId': choiceId,
    'visitedStops': visitedStops,
    'collected': collected,
    if (completedAt != null) 'completedAt': completedAt!.toIso8601String(),
  };
}

/// Original static intervention; [position] is at the prop's feet in metres.
final class VrlzExpeditionWorldProp {
  VrlzExpeditionWorldProp({
    required String kind,
    required String label,
    required String description,
    required List<double> position,
    double radius = 2.5,
  }) : kind = _worldPropKind(kind),
       label = _text(label, 160),
       description = _text(description, 1024),
       position = _position(position),
       radius = _radius(radius);
  final String kind, label, description;
  final List<double> position;
  final double radius;
  Map<String, dynamic> toJson() => {
    'kind': kind,
    'label': label,
    'description': description,
    'position': position.toList(),
    'radius': radius,
  };
  factory VrlzExpeditionWorldProp.fromJson(Map<String, dynamic> json) {
    _keys(json, {'kind', 'label', 'description', 'position', 'radius'});
    try {
      return VrlzExpeditionWorldProp(
        kind: _jsonText(json['kind']),
        label: _jsonText(json['label']),
        description: _jsonText(json['description']),
        position: _jsonPosition(json['position']),
        radius: _jsonRadius(json['radius']),
      );
    } on ArgumentError {
      throw const FormatException('Invalid world prop.');
    }
  }
}

/// A local conditional access. [position] is the centre of its portal.
final class VrlzExpeditionWorldAccess {
  VrlzExpeditionWorldAccess({
    required String label,
    required String destination,
    required List<double> position,
    double radius = 3.5,
  }) : label = _text(label, 160),
       destination = _id(destination),
       position = _position(position),
       radius = _radius(radius);
  final String label, destination;
  final List<double> position;
  final double radius;
  Map<String, dynamic> toJson() => {
    'label': label,
    'destination': destination,
    'position': position.toList(),
    'radius': radius,
  };
  factory VrlzExpeditionWorldAccess.fromJson(Map<String, dynamic> json) {
    _keys(json, {'label', 'destination', 'position', 'radius'});
    try {
      return VrlzExpeditionWorldAccess(
        label: _jsonText(json['label']),
        destination: _jsonText(json['destination']),
        position: _jsonPosition(json['position']),
        radius: _jsonRadius(json['radius']),
      );
    } on ArgumentError {
      throw const FormatException('Invalid world access.');
    }
  }
}

/// First matching intervention per world wins; all conditions need delivery.
final class VrlzExpeditionWorldChange {
  VrlzExpeditionWorldChange({
    required String id,
    required String world,
    required List<VrlzExpeditionStoryRequirement> requires,
    this.prop,
    this.access,
    this.reaction,
  }) : id = _id(id),
       world = _id(world),
       requires = _storyRequirements(requires, nonempty: true) {
    if (prop == null && access == null && reaction == null) {
      throw ArgumentError('A world change needs an intervention.');
    }
    if (access?.destination == world) {
      throw ArgumentError('A world access must leave its origin.');
    }
  }
  final String id, world;
  final List<VrlzExpeditionStoryRequirement> requires;
  final VrlzExpeditionWorldProp? prop;
  final VrlzExpeditionWorldAccess? access;
  final VrlzExpeditionGiver? reaction;
  Map<String, dynamic> toJson() => {
    'id': id,
    'world': world,
    'requires': [for (final condition in requires) condition.toJson()],
    if (prop != null) 'prop': prop!.toJson(),
    if (access != null) 'access': access!.toJson(),
    if (reaction != null) 'reaction': reaction!.toJson(),
  };
  factory VrlzExpeditionWorldChange.fromJson(Map<String, dynamic> json) {
    _keys(
      json,
      {'id', 'world', 'requires'},
      optional: {'prop', 'access', 'reaction'},
    );
    try {
      return VrlzExpeditionWorldChange(
        id: _jsonText(json['id']),
        world: _jsonText(json['world']),
        requires: _jsonStoryRequirements(json['requires']),
        prop: json.containsKey('prop')
            ? VrlzExpeditionWorldProp.fromJson(_jsonMap(json['prop']))
            : null,
        access: json.containsKey('access')
            ? VrlzExpeditionWorldAccess.fromJson(_jsonMap(json['access']))
            : null,
        reaction: json.containsKey('reaction')
            ? VrlzExpeditionGiver.fromJson(_jsonMap(json['reaction']))
            : null,
      );
    } on ArgumentError {
      throw const FormatException('Invalid world change.');
    }
  }
}

/// Bounded campaign data, independent of world textures/content hashes.
final class VrlzExpeditionDefinition {
  VrlzExpeditionDefinition({
    required String id,
    required String experienceId,
    required String title,
    required this.revision,
    required Map<String, String> worlds,
    required List<VrlzExpeditionMission> missions,
    List<VrlzExpeditionSideQuest> sideQuests = const [],
    List<VrlzExpeditionWorldChange> worldChanges = const [],
  }) : id = _id(id),
       experienceId = _id(experienceId),
       title = _text(title, 160),
       worlds = Map.unmodifiable(Map<String, String>.of(worlds)),
       missions = List.unmodifiable(List<VrlzExpeditionMission>.of(missions)),
       sideQuests = List.unmodifiable(sideQuests),
       worldChanges = List.unmodifiable(worldChanges) {
    if (revision < 1 ||
        revision > 2147483647 ||
        worlds.isEmpty ||
        worlds.length > maxWorlds ||
        missions.isEmpty ||
        missions.length > maxMissions ||
        sideQuests.length > maxSideQuests ||
        worldChanges.length > maxWorldChanges) {
      throw ArgumentError(
        'Use a bounded expedition revision, worlds and missions.',
      );
    }
    for (final entry in worlds.entries) {
      _id(entry.key);
      _text(entry.value, 160);
    }
    final ids = <String>{};
    for (final mission in missions) {
      if (!ids.add(mission.id) || !worlds.containsKey(mission.world)) {
        throw ArgumentError('Mission IDs must be unique and use known worlds.');
      }
    }
    final sideIds = <String>{};
    for (final quest in sideQuests) {
      if (!sideIds.add(quest.id) ||
          ids.contains(quest.id) ||
          !ids.contains(quest.afterMissionId) ||
          !worlds.containsKey(quest.world) ||
          quest.choices.any(
            (choice) => choice.route.any((world) => !worlds.containsKey(world)),
          )) {
        throw ArgumentError(
          'Side quests must use unique IDs and known missions/worlds.',
        );
      }
    }
    final byId = {for (final quest in sideQuests) quest.id: quest};
    void checkReferences(List<VrlzExpeditionStoryRequirement> requirements) {
      for (final requirement in requirements) {
        final source = byId[requirement.questId];
        if (source == null ||
            requirement.choiceIds.any(
              (id) => !source.choices.any((choice) => choice.id == id),
            )) {
          throw ArgumentError(
            'Story requirements must reference known choices.',
          );
        }
      }
    }

    for (final quest in sideQuests) {
      checkReferences(quest.requires);
      for (final variant in quest.dialogueVariants) {
        checkReferences(variant.requires);
      }
    }
    final changeIds = <String>{};
    for (final change in worldChanges) {
      if (!changeIds.add(change.id) ||
          ids.contains(change.id) ||
          sideIds.contains(change.id) ||
          !worlds.containsKey(change.world) ||
          change.access != null &&
              !worlds.containsKey(change.access!.destination)) {
        throw ArgumentError('World changes need unique IDs and known worlds.');
      }
      checkReferences(change.requires);
    }
    final visiting = <String>{}, visited = <String>{};
    void checkCycles(VrlzExpeditionSideQuest quest) {
      if (visited.contains(quest.id)) return;
      if (!visiting.add(quest.id)) {
        throw ArgumentError('Story unlock cycles are not allowed.');
      }
      for (final requirement in quest.requires) {
        checkCycles(byId[requirement.questId]!);
      }
      visiting.remove(quest.id);
      visited.add(quest.id);
    }

    for (final quest in sideQuests) {
      checkCycles(quest);
    }

    // A story's prerequisites do not change with its chosen branch, so a DAG
    // closure needs only intersect the permitted choices for each ancestor.
    // This rejects impossible chapters without enumerating 2^N playthroughs.
    void checkCondition(List<VrlzExpeditionStoryRequirement> conditions) {
      final allowed = <String, Set<String>>{}, expanded = <String>{};
      void constrain(VrlzExpeditionStoryRequirement requirement) {
        final previous = allowed[requirement.questId];
        final choices = previous == null
            ? requirement.choiceIds.toSet()
            : previous.intersection(requirement.choiceIds.toSet());
        if (choices.isEmpty) {
          throw ArgumentError(
            'Story unlock requirements contradict their ancestors.',
          );
        }
        allowed[requirement.questId] = choices;
        if (expanded.add(requirement.questId)) {
          for (final parent in byId[requirement.questId]!.requires) {
            constrain(parent);
          }
        }
      }

      for (final requirement in conditions) {
        constrain(requirement);
      }
    }

    for (final quest in sideQuests) {
      checkCondition(quest.requires);
      for (final variant in quest.dialogueVariants) {
        checkCondition([...quest.requires, ...variant.requires]);
      }
    }
    for (final change in worldChanges) {
      checkCondition(change.requires);
    }
    _snapshotUpperBoundBytes = _snapshotUpperBound(this);
    if (_snapshotUpperBoundBytes > maxSnapshotBytes) {
      throw ArgumentError(
        'Expedition progress can exceed 32 KiB; shorten authored identifiers.',
      );
    }
    if (utf8.encode(jsonEncode(toJson())).length > maxBytes) {
      throw ArgumentError('Expedition definition exceeds 256 KiB.');
    }
  }

  static const maxWorlds = 32;
  static const maxMissions = 128;
  static const maxSideQuests = 40;
  static const maxWorldChanges = 80;
  static const maxBytes = 256 * 1024;
  static const maxSnapshotBytes = 32 * 1024;
  late final int _snapshotUpperBoundBytes;

  /// Conservative encoded JSON bound, not measured memory usage. Includes
  /// optional pending/focus reservations even when not all can coexist.
  int get estimatedSnapshotUpperBoundBytes => _snapshotUpperBoundBytes;
  final String id, experienceId, title;
  final int revision;
  final Map<String, String> worlds;
  final List<VrlzExpeditionMission> missions;
  final List<VrlzExpeditionSideQuest> sideQuests;
  final List<VrlzExpeditionWorldChange> worldChanges;

  Map<String, dynamic> toJson() => {
    'schemaVersion': 1,
    'id': id,
    'experienceId': experienceId,
    'title': title,
    'revision': revision,
    'worlds': Map<String, String>.of(worlds),
    'missions': [for (final mission in missions) mission.toJson()],
    if (sideQuests.isNotEmpty)
      'sideQuests': [for (final quest in sideQuests) quest.toJson()],
    if (worldChanges.isNotEmpty)
      'worldChanges': [for (final change in worldChanges) change.toJson()],
  };

  factory VrlzExpeditionDefinition.fromJson(Map<String, dynamic> json) {
    _keys(
      json,
      {
        'schemaVersion',
        'id',
        'experienceId',
        'title',
        'revision',
        'worlds',
        'missions',
      },
      optional: {'sideQuests', 'worldChanges'},
    );
    final worlds = json['worlds'], missions = json['missions'];
    final sideQuests = json.containsKey('sideQuests')
        ? json['sideQuests']
        : const [];
    final worldChanges = json.containsKey('worldChanges')
        ? json['worldChanges']
        : const [];
    if (json['schemaVersion'] is! int ||
        json['schemaVersion'] != 1 ||
        json['revision'] is! int ||
        worlds is! Map ||
        worlds.isEmpty ||
        worlds.length > maxWorlds ||
        worlds.entries.any((e) => e.key is! String || e.value is! String) ||
        missions is! List ||
        missions.isEmpty ||
        missions.length > maxMissions ||
        sideQuests is! List ||
        sideQuests.length > maxSideQuests ||
        worldChanges is! List ||
        worldChanges.length > maxWorldChanges) {
      throw const FormatException('Invalid expedition definition.');
    }
    try {
      return VrlzExpeditionDefinition(
        id: _jsonText(json['id']),
        experienceId: _jsonText(json['experienceId']),
        title: _jsonText(json['title']),
        revision: json['revision'] as int,
        worlds: {
          for (final entry in worlds.entries)
            entry.key as String: entry.value as String,
        },
        missions: [
          for (final mission in missions)
            VrlzExpeditionMission.fromJson(_jsonMap(mission)),
        ],
        sideQuests: [
          for (final quest in sideQuests)
            VrlzExpeditionSideQuest.fromJson(_jsonMap(quest)),
        ],
        worldChanges: [
          for (final change in worldChanges)
            VrlzExpeditionWorldChange.fromJson(_jsonMap(change)),
        ],
      );
    } on ArgumentError {
      throw const FormatException('Invalid expedition definition.');
    }
  }

  factory VrlzExpeditionDefinition.fromBytes(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const FormatException(
        'Expedition definition exceeds its byte limit.',
      );
    }
    return VrlzExpeditionDefinition.fromJson(
      _jsonMap(jsonDecode(utf8.decode(bytes))),
    );
  }
}

String _id(String value) {
  if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,127}$').hasMatch(value)) {
    throw ArgumentError('Use a bounded expedition/world identifier.');
  }
  return value;
}

int _snapshotUpperBound(VrlzExpeditionDefinition definition) {
  const date = '9999-12-31T23:59:59.999999Z';
  String longest(Iterable<String> values) =>
      values.reduce((a, b) => a.length >= b.length ? a : b);
  final pending = definition.missions.where((mission) => mission.giver != null);
  return utf8
      .encode(
        jsonEncode({
          'schema': 1,
          'id': definition.id,
          'experienceId': definition.experienceId,
          'revision': definition.revision,
          'visitedWorlds': {
            for (final world in definition.worlds.keys) world: date,
          },
          'completedMissions': {
            for (final mission in definition.missions) mission.id: date,
          },
          if (pending.isNotEmpty)
            'pendingMission': {
              'missionId': longest(pending.map((mission) => mission.id)),
              'stage': 'collected',
            },
          if (definition.sideQuests.isNotEmpty)
            'sideQuests': {
              for (final quest in definition.sideQuests)
                quest.id: {
                  'choiceId': longest(quest.choices.map((choice) => choice.id)),
                  'visitedStops': 3,
                  'collected': true,
                  'completedAt': date,
                },
            },
          if (definition.sideQuests.isNotEmpty)
            'focusedSideQuestId': longest(
              definition.sideQuests.map((quest) => quest.id),
            ),
        }),
      )
      .length;
}

List<VrlzExpeditionStoryRequirement> _storyRequirements(
  List<VrlzExpeditionStoryRequirement> values, {
  bool nonempty = false,
}) {
  if (values.length > 8 ||
      nonempty && values.isEmpty ||
      values.map((requirement) => requirement.questId).toSet().length !=
          values.length) {
    throw ArgumentError('Use up to eight distinct story requirements.');
  }
  return List.unmodifiable(values);
}

List<VrlzExpeditionStoryRequirement> _jsonStoryRequirements(Object? value) {
  if (value is! List || value.length > 8) {
    throw const FormatException('Invalid story requirements.');
  }
  return [
    for (final requirement in value)
      VrlzExpeditionStoryRequirement.fromJson(_jsonMap(requirement)),
  ];
}

String _text(String value, int limit) {
  if (value.trim().isEmpty ||
      value.length > limit ||
      RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]').hasMatch(value)) {
    throw ArgumentError('Use bounded, nonempty expedition text.');
  }
  return value;
}

List<double> _position(List<double> values) {
  if (values.length != 3 || values.any((v) => !v.isFinite || v.abs() > 1e6)) {
    throw ArgumentError('Use three finite, bounded world coordinates.');
  }
  return List<double>.unmodifiable(values);
}

double _radius(double value) {
  if (!value.isFinite || value < .1 || value > 10) {
    throw ArgumentError('Use a mission radius within 0.1–10 metres.');
  }
  return value;
}

String _objectKind(String value) {
  if (!const {'collect', 'examine', 'activate'}.contains(value)) {
    throw ArgumentError('Use a supported expedition object action kind.');
  }
  return value;
}

String _worldPropKind(String value) {
  if (!const {'planter', 'archive', 'beacon', 'shelter'}.contains(value)) {
    throw ArgumentError('Use a supported world prop kind.');
  }
  return value;
}

String _jsonText(Object? value) {
  if (value is! String) {
    throw const FormatException('Expected expedition text.');
  }
  return value;
}

Map<String, dynamic> _jsonMap(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Expected expedition object.');
  }
  return value;
}

List<double> _jsonPosition(Object? value) {
  if (value is! List || value.length != 3 || value.any((v) => v is! num)) {
    throw const FormatException('Invalid expedition coordinates.');
  }
  return [for (final coordinate in value) (coordinate as num).toDouble()];
}

double _jsonRadius(Object? value) {
  if (value is! num) throw const FormatException('Invalid expedition radius.');
  return value.toDouble();
}

void _keys(
  Map<String, dynamic> value,
  Set<String> expected, {
  Set<String> optional = const {},
}) {
  if (!expected.every(value.containsKey) ||
      !value.keys.every(
        (key) => expected.contains(key) || optional.contains(key),
      )) {
    throw const FormatException('Unsupported expedition fields.');
  }
}
