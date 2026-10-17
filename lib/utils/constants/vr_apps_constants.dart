/// Constants for `vrlizate_apps` spatial mini-app descriptors, registry,
/// and deterministic bundle integrity verification.
abstract final class VrAppsConstants {
  static const String defaultMiniAppVersion = '1.0.0';
  static const double defaultPlacementDistanceMeters = 1.8;
  static const double minPlacementDistanceMeters = 0.5;
  static const double maxPlacementDistanceMeters = 12.0;

  static const String categoryProductivityId = 'productivity';
  static const String categoryWellnessId = 'wellness';
  static const String categoryCreativityId = 'creativity';
  static const String categoryMediaId = 'media';
  static const String categoryUtilitiesId = 'utilities';
  static const String categoryEducationId = 'education';

  static const String keyId = 'id';
  static const String keyTitle = 'title';
  static const String keySubtitle = 'subtitle';
  static const String keyCategory = 'category';
  static const String keyVersion = 'version';
  static const String keySupportsVisor = 'supportsVisor';
  static const String keySupportsHandheld = 'supportsHandheld';
  static const String keyDefaultPlacementDistanceMeters =
      'defaultPlacementDistanceMeters';

  static const String builtinSpatialClockId = 'org.vrlizate.app.spatial_clock';
  static const String builtinSpatialClockTitle = 'Spatial Chrono';
  static const String builtinSpatialClockSubtitle =
      'Floating 3D ambient clock and focus timer';

  static const String builtinBreathSanctuaryId =
      'org.vrlizate.app.breath_sanctuary';
  static const String builtinBreathSanctuaryTitle = 'Breath Sanctuary';
  static const String builtinBreathSanctuarySubtitle =
      'Guided spatial breathing and mindfulness orb';

  static const String builtinStereoGalleryId =
      'org.vrlizate.app.stereo_gallery';
  static const String builtinStereoGalleryTitle = 'Stereo Gallery';
  static const String builtinStereoGallerySubtitle =
      'Spatial 3D media and sculpture showcase';

  static const int minSignatureLength = 4;
  static const int zipLocalHeaderByte0 = 0x50;
  static const int zipLocalHeaderByte1 = 0x4B;
  static const int zipLocalHeaderByte2 = 0x03;
  static const int zipLocalHeaderByte3 = 0x04;

  static const int vrlwMagicByte0 = 0x56;
  static const int vrlwMagicByte1 = 0x52;
  static const int vrlwMagicByte2 = 0x4C;
  static const int vrlwMagicByte3 = 0x57;

  static const int fnv1a32OffsetBasis = 0x811C9DC5;
  static const int fnv1a32Prime = 0x01000193;
  static const int crc32InitialMask = 0xFFFFFFFF;
  static const int crc32Polynomial = 0xEDB88320;
  static const int uint32Mask = 0xFFFFFFFF;
  static const int byteMask = 0xFF;
  static const int bitsPerByte = 8;
  static const int hexRadix = 16;
  static const int hexDigestWidth = 8;
  static const String padZeroChar = '0';
}
