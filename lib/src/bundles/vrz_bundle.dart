import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'vrz_glb.dart';
import 'vrz_manifest.dart';
import 'vrz_zip.dart';

/// Validated, immutable data for an existing v1 scene runtime, never executable code.
final class VrzBundle {
  VrzBundle._(this.manifest, Uint8List scene, this.glbStats, this.source)
    : _scene = Uint8List.fromList(scene);

  static const maxBytes = 32 * 1024 * 1024;
  final VrzManifest manifest;
  final VrzGlbStats glbStats;
  final Uri? source;
  final Uint8List _scene;
  Uint8List get sceneBytes => Uint8List.fromList(_scene);

  static VrzBundle decode(Uint8List bytes, {Uri? source}) {
    final files = readVrzZip(bytes, maxBytes);
    final manifest = VrzManifest.fromJson(
      decodeVrzJson(files['manifest.json']!),
    );
    final scene = files['scene.glb']!;
    if (sha256.convert(scene).toString() != manifest.sceneSha256) {
      throw const FormatException(
        'scene.glb does not match the manifest SHA-256.',
      );
    }
    final stats = inspectVrzGlbStats(
      scene,
      allowExtendedGraphics: manifest.hasExtendedProfile,
    );
    return VrzBundle._(manifest, scene, stats, source);
  }

  /// Creates a STORE-only `vrlizate.scene.v1` bundle (`formatVersion: 1`) and
  /// validates it using the same reader.
  static Uint8List encode({
    required Uint8List sceneBytes,
    required String id,
    required String title,
    String description = '',
    List<String> capabilities = const [VrzManifest.supportedCapability],
    List<double> cameraPosition = const [0, 1.6, 6],
    List<double> cameraTarget = const [0, 1, -6],
    Map<String, Object?> extensions = const {},
  }) => _encodeWithManifest(
    sceneBytes: sceneBytes,
    manifestJson: {
      'formatVersion': VrzManifest.supportedFormatVersion,
      'id': id,
      'title': title,
      'description': description,
      'runtime': VrzManifest.supportedRuntime,
      'entrypoint': 'scene.glb',
      'capabilities': capabilities,
      'sha256': {'scene.glb': sha256.convert(sceneBytes).toString()},
      'camera': {'position': cameraPosition, 'target': cameraTarget},
      if (extensions.isNotEmpty) 'extensions': extensions,
    },
  );

  static Uint8List _encodeWithManifest({
    required Uint8List sceneBytes,
    required Map<String, Object?> manifestJson,
  }) {
    if (sceneBytes.length > maxBytes) {
      throw const FormatException('Scene exceeds the VRZ size budget.');
    }
    final manifest = VrzManifest.fromJson(manifestJson);
    final metadata = utf8.encode(jsonEncode(manifest.toJson()));
    final archive = Archive()
      ..add(ArchiveFile.noCompress('manifest.json', metadata.length, metadata))
      ..add(ArchiveFile.noCompress('scene.glb', sceneBytes.length, sceneBytes));
    final encoded = ZipEncoder().encodeBytes(
      archive,
      modified: DateTime.utc(2000),
    );
    decode(encoded);
    return encoded;
  }
}
