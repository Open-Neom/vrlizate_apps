import '../constants/vr_apps_constants.dart';

/// Categories for spatial mini-apps in the VRlizate ecosystem.
enum VrMiniAppCategory {
  productivity,
  wellness,
  creativity,
  media,
  utilities,
  education;

  /// Stable identifier for serialization and filtering.
  String get id => switch (this) {
    VrMiniAppCategory.productivity => VrAppsConstants.categoryProductivityId,
    VrMiniAppCategory.wellness => VrAppsConstants.categoryWellnessId,
    VrMiniAppCategory.creativity => VrAppsConstants.categoryCreativityId,
    VrMiniAppCategory.media => VrAppsConstants.categoryMediaId,
    VrMiniAppCategory.utilities => VrAppsConstants.categoryUtilitiesId,
    VrMiniAppCategory.education => VrAppsConstants.categoryEducationId,
  };

  /// Resolves a [VrMiniAppCategory] from [id], defaulting to [utilities].
  static VrMiniAppCategory fromId(String id) {
    for (final category in VrMiniAppCategory.values) {
      if (category.id == id || category.name == id) {
        return category;
      }
    }
    return VrMiniAppCategory.utilities;
  }
}
