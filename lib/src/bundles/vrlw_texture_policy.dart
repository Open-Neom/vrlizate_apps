/// The VRLW container supports more resource types than every mobile renderer.
/// flutter_scene 0.24.3 exposes an IBL KTX2 loader, but no public byte loader for
/// regular KTX2 textures. Do not pass these bytes to Flutter's image codec.
abstract final class VrlwTexturePolicy {
  static void validateDecoder(String resourceType) {
    if (resourceType == 'texture.ktx2') {
      throw const FormatException(
        'The mobile VRLW renderer cannot decode texture.ktx2 yet. '
        'Export this texture or panorama as PNG, JPEG or RGBA8. '
        'environment.ktx2 remains supported for pre-baked environments.',
      );
    }
  }
}
