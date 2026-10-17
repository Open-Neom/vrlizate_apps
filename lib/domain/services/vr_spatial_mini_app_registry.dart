import '../../utils/constants/vr_apps_constants.dart';
import '../../utils/enums/vr_mini_app_category.dart';
import '../models/vr_spatial_mini_app_descriptor.dart';

/// Registry for built-in and developer-contributed spatial mini-apps,
/// supporting category and display-mode filtering.
class VrSpatialMiniAppRegistry {
  VrSpatialMiniAppRegistry({bool includeBuiltIns = false}) {
    if (includeBuiltIns) {
      _seedBuiltIns();
    }
  }

  /// Creates a registry pre-populated with the standard built-in mini-apps.
  factory VrSpatialMiniAppRegistry.withBuiltIns() =>
      VrSpatialMiniAppRegistry(includeBuiltIns: true);

  final Map<String, VrSpatialMiniAppDescriptor> _descriptors =
      <String, VrSpatialMiniAppDescriptor>{};
  final Set<String> _builtInIds = <String>{};

  static const List<VrSpatialMiniAppDescriptor> defaultBuiltInDescriptors =
      <VrSpatialMiniAppDescriptor>[
        VrSpatialMiniAppDescriptor(
          id: VrAppsConstants.builtinSpatialClockId,
          title: VrAppsConstants.builtinSpatialClockTitle,
          subtitle: VrAppsConstants.builtinSpatialClockSubtitle,
          category: VrMiniAppCategory.productivity,
        ),
        VrSpatialMiniAppDescriptor(
          id: VrAppsConstants.builtinBreathSanctuaryId,
          title: VrAppsConstants.builtinBreathSanctuaryTitle,
          subtitle: VrAppsConstants.builtinBreathSanctuarySubtitle,
          category: VrMiniAppCategory.wellness,
        ),
        VrSpatialMiniAppDescriptor(
          id: VrAppsConstants.builtinStereoGalleryId,
          title: VrAppsConstants.builtinStereoGalleryTitle,
          subtitle: VrAppsConstants.builtinStereoGallerySubtitle,
          category: VrMiniAppCategory.media,
        ),
      ];

  void _seedBuiltIns() {
    for (final descriptor in defaultBuiltInDescriptors) {
      register(descriptor, isBuiltIn: true);
    }
  }

  /// Registers or updates [descriptor]. Throws [ArgumentError] if invalid.
  void register(
    VrSpatialMiniAppDescriptor descriptor, {
    bool isBuiltIn = false,
  }) {
    if (!descriptor.isValid) {
      throw ArgumentError.value(
        descriptor,
        'descriptor',
        'Invalid VrSpatialMiniAppDescriptor',
      );
    }
    _descriptors[descriptor.id] = descriptor;
    if (isBuiltIn) {
      _builtInIds.add(descriptor.id);
    } else {
      _builtInIds.remove(descriptor.id);
    }
  }

  /// Removes the mini-app with [id], returning true if it was registered.
  bool unregister(String id) {
    _builtInIds.remove(id);
    return _descriptors.remove(id) != null;
  }

  /// Looks up a registered descriptor by [id].
  VrSpatialMiniAppDescriptor? findById(String id) => _descriptors[id];

  /// Returns true if [id] is registered as a built-in mini-app.
  bool isBuiltIn(String id) => _builtInIds.contains(id);

  /// All registered mini-app descriptors in insertion order.
  List<VrSpatialMiniAppDescriptor> get all =>
      List<VrSpatialMiniAppDescriptor>.unmodifiable(_descriptors.values);

  /// Registered built-in mini-app descriptors.
  List<VrSpatialMiniAppDescriptor> get builtInApps =>
      filter(builtInOnly: true);

  /// Registered third-party / developer mini-app descriptors.
  List<VrSpatialMiniAppDescriptor> get developerApps =>
      filter(builtInOnly: false);

  /// Filters registered mini-apps by [category], visor/handheld mode support,
  /// and whether they are built-in or developer-provided.
  List<VrSpatialMiniAppDescriptor> filter({
    VrMiniAppCategory? category,
    bool? requiresVisor,
    bool? requiresHandheld,
    bool? builtInOnly,
  }) {
    final result = <VrSpatialMiniAppDescriptor>[];
    for (final descriptor in _descriptors.values) {
      if (category != null && descriptor.category != category) {
        continue;
      }
      if (requiresVisor == true && !descriptor.supportsVisor) {
        continue;
      }
      if (requiresHandheld == true && !descriptor.supportsHandheld) {
        continue;
      }
      if (builtInOnly != null && isBuiltIn(descriptor.id) != builtInOnly) {
        continue;
      }
      result.add(descriptor);
    }
    return List<VrSpatialMiniAppDescriptor>.unmodifiable(result);
  }
}
