import '../../utils/constants/vr_apps_constants.dart';
import '../../utils/enums/vr_mini_app_category.dart';

/// Metadata descriptor for a built-in or third-party spatial mini-app.
class VrSpatialMiniAppDescriptor {
  const VrSpatialMiniAppDescriptor({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.category,
    this.version = VrAppsConstants.defaultMiniAppVersion,
    this.supportsVisor = true,
    this.supportsHandheld = true,
    this.defaultPlacementDistanceMeters =
        VrAppsConstants.defaultPlacementDistanceMeters,
  });

  final String id;
  final String title;
  final String subtitle;
  final VrMiniAppCategory category;
  final String version;
  final bool supportsVisor;
  final bool supportsHandheld;
  final double defaultPlacementDistanceMeters;

  /// Whether this descriptor satisfies non-empty identity, mode support,
  /// and placement distance bounds.
  bool get isValid =>
      id.trim().isNotEmpty &&
      title.trim().isNotEmpty &&
      version.trim().isNotEmpty &&
      (supportsVisor || supportsHandheld) &&
      defaultPlacementDistanceMeters >=
          VrAppsConstants.minPlacementDistanceMeters &&
      defaultPlacementDistanceMeters <=
          VrAppsConstants.maxPlacementDistanceMeters;

  VrSpatialMiniAppDescriptor copyWith({
    String? id,
    String? title,
    String? subtitle,
    VrMiniAppCategory? category,
    String? version,
    bool? supportsVisor,
    bool? supportsHandheld,
    double? defaultPlacementDistanceMeters,
  }) {
    return VrSpatialMiniAppDescriptor(
      id: id ?? this.id,
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      category: category ?? this.category,
      version: version ?? this.version,
      supportsVisor: supportsVisor ?? this.supportsVisor,
      supportsHandheld: supportsHandheld ?? this.supportsHandheld,
      defaultPlacementDistanceMeters:
          defaultPlacementDistanceMeters ?? this.defaultPlacementDistanceMeters,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    VrAppsConstants.keyId: id,
    VrAppsConstants.keyTitle: title,
    VrAppsConstants.keySubtitle: subtitle,
    VrAppsConstants.keyCategory: category.id,
    VrAppsConstants.keyVersion: version,
    VrAppsConstants.keySupportsVisor: supportsVisor,
    VrAppsConstants.keySupportsHandheld: supportsHandheld,
    VrAppsConstants.keyDefaultPlacementDistanceMeters:
        defaultPlacementDistanceMeters,
  };

  factory VrSpatialMiniAppDescriptor.fromJson(Map<String, Object?> json) {
    final distanceRaw = json[VrAppsConstants.keyDefaultPlacementDistanceMeters];
    return VrSpatialMiniAppDescriptor(
      id: (json[VrAppsConstants.keyId] as String?) ?? '',
      title: (json[VrAppsConstants.keyTitle] as String?) ?? '',
      subtitle: (json[VrAppsConstants.keySubtitle] as String?) ?? '',
      category: VrMiniAppCategory.fromId(
        (json[VrAppsConstants.keyCategory] as String?) ?? '',
      ),
      version:
          (json[VrAppsConstants.keyVersion] as String?) ??
          VrAppsConstants.defaultMiniAppVersion,
      supportsVisor: (json[VrAppsConstants.keySupportsVisor] as bool?) ?? true,
      supportsHandheld:
          (json[VrAppsConstants.keySupportsHandheld] as bool?) ?? true,
      defaultPlacementDistanceMeters: distanceRaw is num
          ? distanceRaw.toDouble()
          : VrAppsConstants.defaultPlacementDistanceMeters,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VrSpatialMiniAppDescriptor &&
          id == other.id &&
          title == other.title &&
          subtitle == other.subtitle &&
          category == other.category &&
          version == other.version &&
          supportsVisor == other.supportsVisor &&
          supportsHandheld == other.supportsHandheld &&
          defaultPlacementDistanceMeters ==
              other.defaultPlacementDistanceMeters;

  @override
  int get hashCode => Object.hash(
    id,
    title,
    subtitle,
    category,
    version,
    supportsVisor,
    supportsHandheld,
    defaultPlacementDistanceMeters,
  );
}
