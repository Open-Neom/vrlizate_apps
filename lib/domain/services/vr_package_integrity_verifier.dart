import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:vrlizate_world/vrlizate_world.dart';

import '../../src/bundles/vrlz_package.dart';
import '../../utils/constants/vr_apps_constants.dart';

/// Deterministic FNV-1a (32-bit), CRC32, SHA-256, header signature identifier,
/// and full structural validator for `.vrlz` (ZIP STORE) and `.vrlw` (world
/// region) bundles.
///
/// - Use [verifySignatureAndChecksum] ONLY for fast 4-byte magic prefix
///   identification (`PK\x03\x04` or `VRLW`) and transport checksum matching;
///   it does **not** decode container manifests or payloads.
/// - Use [verifyBundle] or [validateBundleOrThrow] for complete structural and
///   cryptographic validation matching [VrlzPackage.decode] and [VrlwBundleCodec].
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

  /// Returns the lowercase 64-character SHA-256 hex digest of [bytes].
  static String computeSha256Hex(List<int> bytes) =>
      crypto.sha256.convert(bytes).toString();

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

  /// Checks whether [bytes] begins with the 4-byte `VRLW` ASCII magic prefix.
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

  /// Fast header-prefix and transport checksum preflight ONLY.
  ///
  /// Does **not** decode `.vrlz` or `.vrlw` manifests, schemas, or compressed
  /// chunks. Use [verifyBundle] or [validateBundleOrThrow] before accepting a
  /// package as structurally valid.
  static bool verifySignatureAndChecksum(
    List<int> bytes, {
    int? expectedCrc32,
    int? expectedFnv1a32,
    String? expectedSha256,
    bool requireVrlzSignature = false,
    bool requireVrlwSignature = false,
  }) {
    if (bytes.isEmpty) {
      return false;
    }
    if (requireVrlzSignature && requireVrlwSignature) {
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
    if (expectedSha256 != null &&
        computeSha256Hex(bytes) != expectedSha256.trim().toLowerCase()) {
      return false;
    }
    return true;
  }

  /// Validates [bytes] structurally and cryptographically, throwing
  /// [FormatException] on any malformed header,checksum mismatch, unsupported
  /// runtime schema, truncated container, or corrupt `.vrlz` / `.vrlw` payload.
  static void validateBundleOrThrow(
    List<int> bytes, {
    int? expectedCrc32,
    int? expectedFnv1a32,
    String? expectedSha256,
    bool requireVrlzSignature = false,
    bool requireVrlwSignature = false,
  }) {
    if (!verifySignatureAndChecksum(
      bytes,
      expectedCrc32: expectedCrc32,
      expectedFnv1a32: expectedFnv1a32,
      expectedSha256: expectedSha256,
      requireVrlzSignature: requireVrlzSignature,
      requireVrlwSignature: requireVrlwSignature,
    )) {
      throw const FormatException('Bundle signature or checksum mismatch.');
    }
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    if (hasVrlzZipSignature(data)) {
      VrlzPackage.decode(data);
      return;
    }
    _validateFullVrlwContainer(data);
  }

  /// Performs complete signature, optional digest, and structural container
  /// validation for `.vrlz` and `.vrlw` bundles, returning `false` on any
  /// truncated or malformed input.
  static bool verifyBundle(
    List<int> bytes, {
    int? expectedCrc32,
    int? expectedFnv1a32,
    String? expectedSha256,
    bool requireVrlzSignature = false,
    bool requireVrlwSignature = false,
  }) {
    try {
      validateBundleOrThrow(
        bytes,
        expectedCrc32: expectedCrc32,
        expectedFnv1a32: expectedFnv1a32,
        expectedSha256: expectedSha256,
        requireVrlzSignature: requireVrlzSignature,
        requireVrlwSignature: requireVrlwSignature,
      );
      return true;
    } on FormatException {
      return false;
    } on ArgumentError {
      return false;
    }
  }

  static void _validateFullVrlwContainer(Uint8List data) {
    if (data.length < VrlwBundleCodec.headerSize ||
        data.length > VrlwBundleCodec.maxFileBytes) {
      throw const FormatException('VRLW bundle length is out of bounds.');
    }
    final header = VrlwBundleCodec.parseHeader(
      Uint8List.sublistView(data, 0, VrlwBundleCodec.headerSize),
    );
    if (header.totalLength != data.length) {
      throw const FormatException('VRLW bundle length does not match header.');
    }
    final index = VrlwBundleCodec.parseIndex(
      header,
      Uint8List.sublistView(
        data,
        VrlwBundleCodec.headerSize,
        header.payloadOffset,
      ),
    );
    final world = VrWorldAddress(
      worldId: index.id,
      instanceId: 'integrity',
    );
    final seenEntityIds = <String>{};
    for (final chunk in index.chunks) {
      final start = header.payloadOffset + chunk.offset;
      final end = start + chunk.packedBytes;
      if (start < header.payloadOffset || end > data.length) {
        throw const FormatException('VRLW chunk offset exceeds payload.');
      }
      final entities = VrlwBundleCodec.decodeChunk(
        index,
        chunk,
        Uint8List.sublistView(data, start, end),
        world: world,
        registeredPrototypeIds: index.prototypeIds,
      );
      for (final entity in entities) {
        if (!seenEntityIds.add(entity.id)) {
          throw FormatException(
            'Duplicate entity id across VRLW regions: ${entity.id}',
          );
        }
      }
    }
    for (final resource in index.resources) {
      final start = header.payloadOffset + resource.offset;
      final end = start + resource.packedBytes;
      if (start < header.payloadOffset || end > data.length) {
        throw const FormatException('VRLW resource offset exceeds payload.');
      }
      VrlwBundleCodec.decodeResource(
        index,
        resource,
        Uint8List.sublistView(data, start, end),
      );
    }
  }
}
