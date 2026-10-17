import '../../utils/constants/vr_apps_constants.dart';

/// Deterministic FNV-1a (32-bit), CRC32, and magic byte-signature verifier
/// for `.vrlz` (ZIP STORE) and `.vrlw` (world region) bundles.
abstract final class VrPackageIntegrityVerifier {
  /// Computes the unsigned 32-bit FNV-1a hash of [bytes].
  static int computeFnv1a32(List<int> bytes) {
    var hash = VrAppsConstants.fnv1a32OffsetBasis;
    for (final byte in bytes) {
      hash ^= (byte & VrAppsConstants.byteMask);
      hash = (hash * VrAppsConstants.fnv1a32Prime) & VrAppsConstants.uint32Mask;
    }
    return hash;
  }

  /// Returns the lowercase 8-character hex string of [computeFnv1a32].
  static String computeFnv1a32Hex(List<int> bytes) => computeFnv1a32(bytes)
      .toRadixString(VrAppsConstants.hexRadix)
      .padLeft(VrAppsConstants.hexDigestWidth, VrAppsConstants.padZeroChar);

  /// Computes the standard IEEE 802.3 unsigned 32-bit CRC32 of [bytes].
  static int computeCrc32(List<int> bytes) {
    var crc = VrAppsConstants.crc32InitialMask;
    for (final byte in bytes) {
      crc ^= (byte & VrAppsConstants.byteMask);
      for (var bit = 0; bit < VrAppsConstants.bitsPerByte; bit++) {
        final lsb = crc & 1;
        crc = (crc >>> 1) & VrAppsConstants.uint32Mask;
        if (lsb != 0) {
          crc ^= VrAppsConstants.crc32Polynomial;
        }
      }
    }
    return (~crc) & VrAppsConstants.uint32Mask;
  }

  /// Returns the lowercase 8-character hex string of [computeCrc32].
  static String computeCrc32Hex(List<int> bytes) => computeCrc32(bytes)
      .toRadixString(VrAppsConstants.hexRadix)
      .padLeft(VrAppsConstants.hexDigestWidth, VrAppsConstants.padZeroChar);

  /// Checks whether [bytes] begins with the ZIP local file header (`PK\x03\x04`)
  /// used by `.vrlz` packages.
  static bool hasVrlzZipSignature(List<int> bytes) {
    if (bytes.length < VrAppsConstants.minSignatureLength) {
      return false;
    }
    return (bytes[0] & VrAppsConstants.byteMask) ==
            VrAppsConstants.zipLocalHeaderByte0 &&
        (bytes[1] & VrAppsConstants.byteMask) ==
            VrAppsConstants.zipLocalHeaderByte1 &&
        (bytes[2] & VrAppsConstants.byteMask) ==
            VrAppsConstants.zipLocalHeaderByte2 &&
        (bytes[3] & VrAppsConstants.byteMask) ==
            VrAppsConstants.zipLocalHeaderByte3;
  }

  /// Checks whether [bytes] begins with the `VRLW` ASCII magic signature
  /// used by `.vrlw` world bundles.
  static bool hasVrlwMagicSignature(List<int> bytes) {
    if (bytes.length < VrAppsConstants.minSignatureLength) {
      return false;
    }
    return (bytes[0] & VrAppsConstants.byteMask) ==
            VrAppsConstants.vrlwMagicByte0 &&
        (bytes[1] & VrAppsConstants.byteMask) ==
            VrAppsConstants.vrlwMagicByte1 &&
        (bytes[2] & VrAppsConstants.byteMask) ==
            VrAppsConstants.vrlwMagicByte2 &&
        (bytes[3] & VrAppsConstants.byteMask) ==
            VrAppsConstants.vrlwMagicByte3;
  }

  /// Returns true if [bytes] begins with either a `.vrlz` ZIP signature
  /// or a `.vrlw` magic header.
  static bool hasRecognizedBundleSignature(List<int> bytes) =>
      hasVrlzZipSignature(bytes) || hasVrlwMagicSignature(bytes);

  /// Verifies [bytes] against optional signature requirements and expected
  /// CRC32 / FNV-1a digests.
  static bool verifyBundle(
    List<int> bytes, {
    int? expectedCrc32,
    int? expectedFnv1a32,
    bool requireVrlzSignature = false,
    bool requireVrlwSignature = false,
  }) {
    if (bytes.isEmpty) {
      return false;
    }
    if (requireVrlzSignature && !hasVrlzZipSignature(bytes)) {
      return false;
    }
    if (requireVrlwSignature && !hasVrlwMagicSignature(bytes)) {
      return false;
    }
    if (!requireVrlzSignature &&
        !requireVrlwSignature &&
        !hasRecognizedBundleSignature(bytes)) {
      return false;
    }
    if (expectedCrc32 != null &&
        computeCrc32(bytes) != (expectedCrc32 & VrAppsConstants.uint32Mask)) {
      return false;
    }
    if (expectedFnv1a32 != null &&
        computeFnv1a32(bytes) !=
            (expectedFnv1a32 & VrAppsConstants.uint32Mask)) {
      return false;
    }
    return true;
  }
}
