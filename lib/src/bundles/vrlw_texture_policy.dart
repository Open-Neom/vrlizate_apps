import 'dart:typed_data';

import 'package:vrlizate_scene/vrlizate_scene.dart'
    show VrKtx2Codec, VrKtx2HeaderInfo;

/// Portable world (`VRLW`) texture decoder policy across format versions:
/// - **v1 (`allowKtx2Textures: false`, frozen portable contract):** rejects
///   `texture.ktx2` before any image codec or GPU allocation runs.
/// - **v2 (`allowKtx2Textures: true`):** admits 2D `texture.ktx2` (`UASTC`,
///   `ETC1S`, RGBA8, and `universal/1` 4x4 block payloads), validating header
///   geometry and returning hardware block-compressed VRAM estimates (`ASTC 4x4`
///   / `ETC2` / `BC`).
abstract final class VrlwTexturePolicy {
  static const int maxV2Ktx2Dimension = 2048;

  static void validateDecoder(
    String resourceType, {
    bool allowKtx2Textures = false,
  }) {
    if (resourceType == 'texture.ktx2' && !allowKtx2Textures) {
      throw const FormatException(
        'The mobile VRLW renderer cannot decode texture.ktx2 yet. '
        'Export this texture or panorama as PNG, JPEG or RGBA8. '
        'environment.ktx2 remains supported for pre-baked environments.',
      );
    }
  }

  /// Validates decoded `texture.ktx2` container bytes for v2 worlds and returns
  /// parsed header + GPU VRAM accounting.
  static VrKtx2HeaderInfo validateKtx2Payload(
    Uint8List bytes, {
    int? declaredWidth,
    int? declaredHeight,
    int maxDimension = maxV2Ktx2Dimension,
  }) {
    final info = VrKtx2Codec.inspectKtx2Header(bytes);
    if (!info.isSupportedRuntime2dTexture) {
      throw FormatException(
        'Unsupported VRLW v2 texture.ktx2 payload '
        '(dfd=${info.dfdColorModel}, vk=${info.vkFormat}, faces=${info.faceCount}).',
      );
    }
    if (info.width > maxDimension || info.height > maxDimension) {
      throw FormatException(
        'VRLW v2 texture.ktx2 (${info.width}x${info.height}) exceeds '
        'max dimension $maxDimension.',
      );
    }
    if (declaredWidth != null && declaredWidth != info.width) {
      throw FormatException(
        'VRLW v2 texture.ktx2 width (${info.width}) does not match '
        'declared resource width ($declaredWidth).',
      );
    }
    if (declaredHeight != null && declaredHeight != info.height) {
      throw FormatException(
        'VRLW v2 texture.ktx2 height (${info.height}) does not match '
        'declared resource height ($declaredHeight).',
      );
    }
    return info;
  }
}
