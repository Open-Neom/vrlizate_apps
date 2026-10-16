import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'vrlz_builtin_manifest.dart';
import 'vrlz_nes_bundle.dart';
import 'vrlz_nes_manifest.dart';
import 'vrlz_retro_bundle.dart';
import 'vrlz_retro_level.dart';
import 'vrlz_retro_manifest.dart';
import 'vrz_bundle.dart';
import 'vrz_glb.dart' show decodeVrzJson;
import 'vrz_manifest.dart';
import 'vrz_zip.dart';
import 'vrlz_world_bundle.dart';
import 'vrlz_world_manifest.dart';

enum VrlzPackageKind { scene, builtin, nes, retro, worlds }

/// Validated VRLZ content for an explicitly supported host runtime.
///
/// A builtin package is not a downloaded implementation. Its [demoId] must be
/// resolved against an explicit catalog compiled into the receiving host.
final class VrlzPackage {
  VrlzPackage._scene(VrzBundle scene)
    : kind = VrlzPackageKind.scene,
      sceneBundle = scene,
      builtinManifest = null,
      nesBundle = null,
      retroBundle = null,
      worldBundle = null,
      source = scene.source;

  VrlzPackage._builtin(VrlzBuiltinManifest manifest, this.source)
    : kind = VrlzPackageKind.builtin,
      sceneBundle = null,
      nesBundle = null,
      retroBundle = null,
      worldBundle = null,
      builtinManifest = manifest;

  VrlzPackage._nes(VrlzNesBundle bundle)
    : kind = VrlzPackageKind.nes,
      sceneBundle = null,
      builtinManifest = null,
      nesBundle = bundle,
      retroBundle = null,
      worldBundle = null,
      source = bundle.source;

  VrlzPackage._retro(VrlzRetroBundle bundle)
    : kind = VrlzPackageKind.retro,
      sceneBundle = null,
      builtinManifest = null,
      nesBundle = null,
      retroBundle = bundle,
      worldBundle = null,
      source = bundle.source;

  VrlzPackage._worlds(VrlzWorldBundle bundle)
    : kind = VrlzPackageKind.worlds,
      sceneBundle = null,
      builtinManifest = null,
      nesBundle = null,
      retroBundle = null,
      worldBundle = bundle,
      source = bundle.source;

  static const maxBytes = VrzBundle.maxBytes;
  final VrlzPackageKind kind;
  final Uri? source;
  final VrzBundle? sceneBundle;
  final VrlzBuiltinManifest? builtinManifest;
  final VrlzNesBundle? nesBundle;
  final VrlzRetroBundle? retroBundle;
  final VrlzWorldBundle? worldBundle;
  String get id =>
      sceneBundle?.manifest.id ??
      builtinManifest?.id ??
      nesBundle?.manifest.id ??
      retroBundle?.manifest.id ??
      worldBundle!.manifest.id;
  String get title =>
      sceneBundle?.manifest.title ??
      builtinManifest?.title ??
      nesBundle?.manifest.title ??
      retroBundle?.manifest.title ??
      worldBundle!.manifest.title;
  String get description =>
      sceneBundle?.manifest.description ??
      builtinManifest?.description ??
      nesBundle?.manifest.description ??
      retroBundle?.manifest.description ??
      worldBundle!.manifest.description;
  String? get demoId => builtinManifest?.demoId;

  /// Rebuilds a validated STORE container without retaining downloaded bytes.
  /// Metadata and camera are preserved; [source] is transport provenance only.
  Uint8List encode() {
    if (worldBundle != null) return worldBundle!.encodeBundle();
    final scene = sceneBundle;
    if (scene != null) {
      final manifest = scene.manifest;
      return VrzBundle.encode(
        sceneBytes: scene.sceneBytes,
        id: manifest.id,
        title: manifest.title,
        description: manifest.description,
        cameraPosition: manifest.cameraPosition,
        cameraTarget: manifest.cameraTarget,
      );
    }
    final nes = nesBundle;
    if (nes != null) {
      final manifest = nes.manifest;
      return encodeNes(
        romBytes: nes.romBytes,
        id: manifest.id,
        title: manifest.title,
        description: manifest.description,
        license: manifest.license,
        sourceUrl: manifest.sourceUrl,
      );
    }
    final retro = retroBundle;
    if (retro != null) {
      final manifest = retro.manifest;
      return encodeRetro(
        level: retro.level,
        id: manifest.id,
        title: manifest.title,
        description: manifest.description,
        license: manifest.license,
      );
    }
    return encodeBuiltin(
      id: id,
      title: title,
      description: description,
      demoId: demoId!,
    );
  }

  static VrlzPackage decode(Uint8List bytes, {Uri? source}) {
    if (VrlzWorldBundle.hasRawVrlwMagic(bytes)) {
      return VrlzPackage._worlds(
        VrlzWorldBundle.fromRawVrlw(bytes, source: source),
      );
    }
    final files = readVrzZip(
      bytes,
      maxBytes,
      allowManifestOnly: true,
      maxEntries: 9,
      allowAdditionalFile: VrlzWorldBundle.isWorldFile,
      allowedFiles: const {
        'manifest.json',
        'scene.glb',
        'game.nes',
        'level.json',
      },
    );
    final json = decodeVrzJson(files['manifest.json']!);
    if (json['formatVersion'] is int &&
        json['formatVersion'] == 1 &&
        json['runtime'] == VrlzWorldManifest.runtime) {
      return VrlzPackage._worlds(VrlzWorldBundle.decode(bytes, source: source));
    }
    // Select the runtime before validating its payload; a broken scene must
    // never be retried as a builtin descriptor or another runtime.
    if (json['formatVersion'] is int &&
        json['formatVersion'] == 1 &&
        json['runtime'] == VrzManifest.supportedRuntime) {
      return VrlzPackage._scene(VrzBundle.decode(bytes, source: source));
    }
    if (json['formatVersion'] is int &&
        json['formatVersion'] == VrlzBuiltinManifest.supportedFormatVersion &&
        json['runtime'] == VrlzBuiltinManifest.supportedRuntime) {
      if (files.length != 1) {
        throw const FormatException(
          'Builtin VRLZ must contain only manifest.json.',
        );
      }
      return VrlzPackage._builtin(VrlzBuiltinManifest.fromJson(json), source);
    }
    if (json['formatVersion'] is int &&
        json['formatVersion'] == VrlzNesManifest.supportedFormatVersion &&
        json['runtime'] == VrlzNesManifest.supportedRuntime) {
      return VrlzPackage._nes(VrlzNesBundle.decode(bytes, source: source));
    }
    if (json['formatVersion'] is int &&
        json['formatVersion'] == VrlzRetroManifest.supportedFormatVersion &&
        json['runtime'] == VrlzRetroManifest.supportedRuntime) {
      return VrlzPackage._retro(VrlzRetroBundle.decode(bytes, source: source));
    }
    throw const FormatException('Unsupported VRLZ format version or runtime.');
  }

  /// Packages bounded tile data for the host's retro 2.5D game runtime.
  static Uint8List encodeRetro({
    required VrlzRetroLevel level,
    required String id,
    required String title,
    String description = '',
    required String license,
  }) => VrlzRetroBundle.encode(
    level: level,
    id: id,
    title: title,
    description: description,
    license: license,
  );

  /// Creates a cartridge package for the bundled NES runtime, with no native
  /// library, executable Flutter application or save data in the archive.
  static Uint8List encodeNes({
    required Uint8List romBytes,
    required String id,
    required String title,
    String description = '',
    required String license,
    required String sourceUrl,
  }) => VrlzNesBundle.encode(
    romBytes: romBytes,
    id: id,
    title: title,
    description: description,
    license: license,
    sourceUrl: sourceUrl,
  );

  /// Creates an in-memory [VrlzPackage] directly from a validated `.nes` ROM.
  static VrlzPackage fromRawNesRom(
    Uint8List romBytes, {
    required String fileName,
    Uri? source,
  }) => VrlzPackage._nes(
    VrlzNesBundle.fromRawRom(romBytes, fileName: fileName, source: source),
  );

  /// Creates a deterministic STORE-only descriptor, then validates its bytes.
  static Uint8List encodeBuiltin({
    required String id,
    required String title,
    required String demoId,
    String description = '',
  }) {
    final manifest = VrlzBuiltinManifest.fromJson({
      'formatVersion': VrlzBuiltinManifest.supportedFormatVersion,
      'id': id,
      'title': title,
      'description': description,
      'runtime': VrlzBuiltinManifest.supportedRuntime,
      'entrypoint': demoId,
      'capabilities': [VrlzBuiltinManifest.supportedCapability],
      'sha256': <String, String>{},
    });
    final metadata = utf8.encode(jsonEncode(manifest.toJson()));
    final archive = Archive()
      ..add(ArchiveFile.noCompress('manifest.json', metadata.length, metadata));
    final encoded = ZipEncoder().encodeBytes(
      archive,
      modified: DateTime.utc(2000),
    );
    decode(encoded);
    return encoded;
  }
}
