import 'dart:typed_data';

import 'package:vrlizate_scene/vrlizate_scene.dart'
    show VrKtx2Codec, VrKtx2HeaderInfo;

/// Portable world (`VRLW` v1) texture decoder policy:
/// - **Base `worlds.local` (`allowKtx2Textures: false`):** rejects
///   `texture.ktx2` before any image codec or GPU allocation runs.
/// - **`worlds.ktx2` capability (`allowKtx2Textures: true` in `vrlizate.worlds.v1`):**
///   admits 2D `texture.ktx2` (`UASTC`, `ETC1S`, RGBA8, and `universal/1` 4x4
///   block payloads), validating header geometry and returning hardware
///   block-compressed VRAM estimates (`ASTC 4x4` / `ETC2` / `BC`).
abstract final class VrlwTexturePolicy {
  static const int maxKtx2Dimension = 2048;

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

  /// Validates decoded `texture.ktx2` container bytes for `vrlizate.worlds.v1`
  /// (`worlds.ktx2`) and returns parsed header + GPU VRAM accounting.
  static VrKtx2HeaderInfo validateKtx2Payload(
    Uint8List bytes, {
    int? declaredWidth,
    int? declaredHeight,
    int maxDimension = maxKtx2Dimension,
  }) {
    final info = VrKtx2Codec.inspectKtx2Header(bytes);
    if (!info.isSupportedRuntime2dTexture) {
      throw FormatException(
        'Unsupported VRLW texture.ktx2 payload '
        '(dfd=${info.dfdColorModel}, vk=${info.vkFormat}, faces=${info.faceCount}).',
      );
    }
    if (info.width > maxDimension || info.height > maxDimension) {
      throw FormatException(
        'VRLW texture.ktx2 (${info.width}x${info.height}) exceeds '
        'max dimension $maxDimension.',
      );
    }
    if (declaredWidth != null && declaredWidth != info.width) {
      throw FormatException(
        'VRLW texture.ktx2 width (${info.width}) does not match '
        'declared resource width ($declaredWidth).',
      );
    }
    if (declaredHeight != null && declaredHeight != info.height) {
      throw FormatException(
        'VRLW texture.ktx2 height (${info.height}) does not match '
        'declared resource height ($declaredHeight).',
      );
    }
    return info;
  }
}
