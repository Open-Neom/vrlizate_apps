import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart' as fs;
import 'package:vrlizate_world/vrlizate_world.dart';

import '../bundles/vrlw_texture_policy.dart';

/// Resolves the visible sky independently of the image-based lighting source.
/// The generic callbacks also keep resource selection testable without a GPU.
Future<T?> loadVrlwAuthoredSky<T>(
  VrlwEnvironmentSpec? environment, {
  required String Function(String id) resourceType,
  required Future<T> Function(String id) fromEnvironment,
  required Future<T> Function(String id) fromTexture,
  bool allowKtx2Textures = false,
}) async {
  final id = environment?.skyboxResource;
  if (id == null) return null;
  final type = resourceType(id);
  VrlwTexturePolicy.validateDecoder(
    type,
    allowKtx2Textures: allowKtx2Textures,
  );
  return switch (type) {
    'environment.ktx2' => fromEnvironment(id),
    'texture.rgba8' ||
    'texture.png' ||
    'texture.jpeg' ||
    'texture.ktx2' => fromTexture(id),
    _ => throw const FormatException('Unsupported visible sky resource.'),
  };
}

/// Uses flutter_scene's existing sky shader and its public uniform/texture API.
/// A separate sky never replaces Scene.environment or triggers an IBL bake.
/// The bindings follow flutter_scene 0.24.3's SkyboxEnvironment shader contract.
fs.Skybox vrlwEnvironmentSkybox(fs.EnvironmentMap environment) => fs.Skybox(
  _skySource(
    radiance: environment.prefilteredRadiance,
    cube: environment.usesCubeRadianceLayout,
    mip: environment.usesMipRadianceLayout,
    background: environment.backgroundTexture,
    hasBackground: environment.hasBackgroundTexture,
    backgroundIsLinear: environment.backgroundIsLinear,
  ),
);

/// The image is an sRGB equirectangular panorama. Its mip chain is reused;
/// the black radiance placeholder is never visible at blurriness zero.
fs.Skybox vrlwTextureSkybox(fs.TextureSource texture, fs.EnvironmentMap empty) {
  final gpuTex = texture.sampledTexture;
  if (gpuTex == null) {
    throw StateError('Skybox texture source has no realized GPU texture.');
  }
  return fs.Skybox(
    _skySource(
      radiance: empty.prefilteredRadiance,
      cube: false,
      mip: false,
      background: gpuTex,
      hasBackground: true,
      backgroundIsLinear: false,
    ),
  );
}

fs.ShaderSkySource _skySource({
  required gpu.Texture radiance,
  required bool cube,
  required bool mip,
  required gpu.Texture background,
  required bool hasBackground,
  required bool backgroundIsLinear,
}) {
  // KTX2 maps are immutable after upload: select their sampler layout once.
  // No useEnvironment binding: these samplers belong to the explicit sky,
  // independently of the scene's lighting and its day/night intensity.
  final source = VrlwSkyShader(
    cube: cube,
    mip: mip,
    hasBackground: hasBackground,
    backgroundIsLinear: backgroundIsLinear,
  );
  final sampler = gpu.SamplerOptions(
    minFilter: gpu.MinMagFilter.linear,
    magFilter: gpu.MinMagFilter.linear,
    mipFilter: cube || mip ? gpu.MipFilter.linear : gpu.MipFilter.nearest,
    widthAddressMode: cube
        ? gpu.SamplerAddressMode.clampToEdge
        : gpu.SamplerAddressMode.repeat,
    heightAddressMode: gpu.SamplerAddressMode.clampToEdge,
  );
  source.setTexture('prefiltered_radiance', radiance, sampler: sampler);
  source.setTexture('prefiltered_radiance_b', radiance, sampler: sampler);
  source.setTexture(
    'environment_background',
    background,
    sampler: gpu.SamplerOptions(
      minFilter: gpu.MinMagFilter.linear,
      magFilter: gpu.MinMagFilter.linear,
      mipFilter: gpu.MipFilter.linear,
      widthAddressMode: gpu.SamplerAddressMode.repeat,
      heightAddressMode: gpu.SamplerAddressMode.clampToEdge,
    ),
  );
  return source;
}

/// Fixed shader layout, inspectable before native GPU initialization.
final class VrlwSkyShader extends fs.ShaderSkySource {
  VrlwSkyShader({
    required bool cube,
    required bool mip,
    required bool hasBackground,
    required bool backgroundIsLinear,
  }) : super(
         fragmentShaderName: cube
             ? 'SkyboxEnvironmentCubeFragment'
             : 'SkyboxEnvironmentFragment',
       ) {
    setUniformBlockFromFloats('SkyboxInfo', [
      0, // Sharp sky.
      1, // Visible-sky intensity; scene exposure still applies.
      hasBackground ? 1 : 0,
      backgroundIsLinear ? 1 : 0,
      0, // No cross-fade toward a second environment.
      0, 0, 0, // std140 padding.
    ]);
    // The cube variant has no live layout uniform; binding it would fail.
    if (!cube) {
      setUniformBlockFromFloats('RadianceLayoutInfo', [mip ? 1 : 0, 0, 0, 0]);
    }
  }
}
