import 'dart:convert';
import 'dart:typed_data';

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
import 'vrlz_stream_archive.dart';
import 'vrlz_stream_source.dart';
import 'vrlz_world_bundle.dart';
import 'vrlz_world_manifest.dart';
import 'vrlz_web_game_manifest.dart';

enum VrlzPackageKind { scene, builtin, nes, retro, worlds, webgame }

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
      webGameManifest = null,
      worldBundle = null,
      source = scene.source;

  VrlzPackage._builtin(VrlzBuiltinManifest manifest, this.source)
    : kind = VrlzPackageKind.builtin,
      sceneBundle = null,
      nesBundle = null,
      retroBundle = null,
      webGameManifest = null,
      worldBundle = null,
      builtinManifest = manifest;

  VrlzPackage._nes(VrlzNesBundle bundle)
    : kind = VrlzPackageKind.nes,
      sceneBundle = null,
      builtinManifest = null,
      nesBundle = bundle,
      retroBundle = null,
      webGameManifest = null,
      worldBundle = null,
      source = bundle.source;

  VrlzPackage._retro(VrlzRetroBundle bundle)
    : kind = VrlzPackageKind.retro,
      sceneBundle = null,
      builtinManifest = null,
      nesBundle = null,
      retroBundle = bundle,
      webGameManifest = null,
      worldBundle = null,
      source = bundle.source;

  VrlzPackage._worlds(VrlzWorldBundle bundle)
    : kind = VrlzPackageKind.worlds,
      sceneBundle = null,
      builtinManifest = null,
      nesBundle = null,
      retroBundle = null,
      webGameManifest = null,
      worldBundle = bundle,
      source = bundle.source;

  VrlzPackage._webgame(VrlzWebGameManifest manifest, this.source)
    : kind = VrlzPackageKind.webgame,
      sceneBundle = null,
      builtinManifest = null,
      nesBundle = null,
      retroBundle = null,
      worldBundle = null,
      webGameManifest = manifest;

  static const maxBytes = VrzBundle.maxBytes;
  final VrlzPackageKind kind;
  final Uri? source;
  final VrzBundle? sceneBundle;
  final VrlzBuiltinManifest? builtinManifest;
  final VrlzNesBundle? nesBundle;
  final VrlzRetroBundle? retroBundle;
  final VrlzWorldBundle? worldBundle;
  final VrlzWebGameManifest? webGameManifest;
  String get id =>
      sceneBundle?.manifest.id ??
      builtinManifest?.id ??
      nesBundle?.manifest.id ??
      retroBundle?.manifest.id ??
      webGameManifest?.id ??
      worldBundle!.manifest.id;
  String get title =>
      sceneBundle?.manifest.title ??
      builtinManifest?.title ??
      nesBundle?.manifest.title ??
      retroBundle?.manifest.title ??
      webGameManifest?.title ??
      worldBundle!.manifest.title;
  String get description =>
      sceneBundle?.manifest.description ??
      builtinManifest?.description ??
      nesBundle?.manifest.description ??
      retroBundle?.manifest.description ??
      webGameManifest?.description ??
      worldBundle!.manifest.description;
  String? get demoId => builtinManifest?.demoId;

  /// Whether this package carries self-contained creator-authored data eligible
  /// for budgeted submission (excluding platform demo pointers and external ROMs).
  bool get isCreatorSubmittable =>
      kind == VrlzPackageKind.scene ||
      kind == VrlzPackageKind.worlds ||
      kind == VrlzPackageKind.retro;

  /// Rebuilds a validated STORE container without retaining downloaded bytes.
  /// Metadata and camera are preserved; [source] is transport provenance only.
  Uint8List encode() {
    if (webGameManifest != null) {
      return encodeWebGame(manifest: webGameManifest!);
    }
    if (worldBundle != null) return worldBundle!.encodeBundle();
    final scene = sceneBundle;
    if (scene != null) {
      final manifest = scene.manifest;
      if (manifest.isV2) {
        return VrzBundle.encodeV2(
          sceneBytes: scene.sceneBytes,
          id: manifest.id,
          title: manifest.title,
          description: manifest.description,
          capabilities: manifest.capabilities,
          cameraPosition: manifest.cameraPosition,
          cameraTarget: manifest.cameraTarget,
          extensions: manifest.extensions,
        );
      }
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

  static VrlzPackage decode(
    Uint8List bytes, {
    Uri? source,
    bool allowRawVrlwV2 = false,
  }) {
    if (VrlzWorldBundle.hasRawVrlwMagic(bytes)) {
      return VrlzPackage._worlds(
        VrlzWorldBundle.fromRawVrlw(
          bytes,
          source: source,
          allowV2: allowRawVrlwV2,
        ),
      );
    }
    final files = readVrzZip(
      bytes,
      maxBytes,
      allowManifestOnly: true,
      maxEntries: VrlzWorldManifest.maxWorlds + 1,
      maxManifestBytes: VrlzWebGameManifest.maxIndexBytes,
      allowAdditionalFile: VrlzWorldBundle.isWorldFile,
      allowedFiles: const {
        'manifest.json',
        'scene.glb',
        'game.nes',
        'level.json',
      },
    );
    if (files['manifest.json']!.length > VrlzWebGameManifest.maxIndexBytes) {
      throw const FormatException('VRLZ manifest exceeds its metadata budget.');
    }
    final json = decodeVrzJson(files['manifest.json']!);
    if (json['runtime'] != VrlzWebGameManifest.runtime &&
        files['manifest.json']!.length > 65536) {
      throw const FormatException('Legacy VRLZ manifest exceeds 64 KiB.');
    }
    if (json['formatVersion'] is int &&
        ((json['formatVersion'] == 1 &&
                json['runtime'] == VrlzWorldManifest.runtime) ||
            (json['formatVersion'] == 2 &&
                json['runtime'] == VrlzWorldManifest.runtimeV2))) {
      return VrlzPackage._worlds(VrlzWorldBundle.decode(bytes, source: source));
    }
    if (json['runtime'] == VrlzWebGameManifest.runtime) {
      if (files.length != 1 ||
          bytes.length > VrlzWebGameManifest.maxIndexBytes) {
        throw const FormatException(
          'Webgame VRLZ must contain only a bounded manifest.json.',
        );
      }
      return VrlzPackage._webgame(VrlzWebGameManifest.fromJson(json), source);
    }
    // Select the runtime before validating its payload; a broken scene must
    // never be retried as a builtin descriptor or another runtime.
    if (json['formatVersion'] is int &&
        ((json['formatVersion'] == 1 &&
                json['runtime'] == VrzManifest.supportedRuntime) ||
            (json['formatVersion'] == 2 &&
                json['runtime'] == VrzManifest.supportedRuntimeV2))) {
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

  /// Opens a `.vrlz` package directly from an Android Storage Access Framework
  /// `content://` URI via JNI (`ContentResolver.openFileDescriptor().detachFd()`)
  /// and streams over POSIX `pread()` without copying the archive to cache.
  static Future<VrlzPackage> openAndroidSafUri(
    String contentUri, {
    int maxArchiveBytes = VrlzWorldBundle.maxStreamArchiveBytes,
    int maxMemoryCacheBytes = VrlzStreamArchive.defaultMaxMemoryCacheBytes,
    int tempFileThresholdBytes =
        VrlzStreamArchive.defaultTempFileThresholdBytes,
  }) async {
    final randomSource = await VrlzRandomAccessSource.openAndroidSafUri(
      contentUri,
    );
    return openStream(
      randomSource,
      source: Uri.tryParse(contentUri),
      ownsSource: true,
      maxArchiveBytes: maxArchiveBytes,
      maxMemoryCacheBytes: maxMemoryCacheBytes,
      tempFileThresholdBytes: tempFileThresholdBytes,
    );
  }

  /// Opens a `.vrlz` package from a [VrlzRandomAccessSource] (file path or
  /// Android SAF `fd:<n>/<name>` descriptor) without eagerly unpacking multi-world
  /// `.vrlz` containers into heap memory.
  static Future<VrlzPackage> openStream(
    VrlzRandomAccessSource randomSource, {
    Uri? source,
    bool ownsSource = true,
    int maxArchiveBytes = VrlzWorldBundle.maxStreamArchiveBytes,
    int maxMemoryCacheBytes = VrlzStreamArchive.defaultMaxMemoryCacheBytes,
    int tempFileThresholdBytes =
        VrlzStreamArchive.defaultTempFileThresholdBytes,
  }) async {
    final archive = await VrlzStreamArchive.open(
      randomSource,
      ownsSource: ownsSource,
      allowManifestOnly: true,
      maxArchiveBytes: maxArchiveBytes,
      maxEntries: VrlzWorldManifest.maxWorlds + 1,
      maxMemoryCacheBytes: maxMemoryCacheBytes,
      tempFileThresholdBytes: tempFileThresholdBytes,
    );
    var keepArchiveOpen = false;
    try {
      final metadata = await archive.readEntryBytes('manifest.json');
      final json = decodeVrzJson(metadata);
      if (json['formatVersion'] is int &&
          ((json['formatVersion'] == 1 &&
                  json['runtime'] == VrlzWorldManifest.runtime) ||
              (json['formatVersion'] == 2 &&
                  json['runtime'] == VrlzWorldManifest.runtimeV2))) {
        final worldManifest = VrlzWorldManifest.fromJson(json);
        final worldBundle = await VrlzWorldBundle.fromStreamArchive(
          archive,
          metadataBytes: metadata,
          manifest: worldManifest,
          source: source,
        );
        keepArchiveOpen = true;
        return VrlzPackage._worlds(worldBundle);
      }
      if (json['runtime'] == VrlzWebGameManifest.runtime) {
        if (archive.entries.length != 1) {
          throw const FormatException(
            'Webgame VRLZ must contain only a bounded manifest.json.',
          );
        }
        return VrlzPackage._webgame(VrlzWebGameManifest.fromJson(json), source);
      }
      if (json['formatVersion'] is int &&
          json['formatVersion'] == VrlzBuiltinManifest.supportedFormatVersion &&
          json['runtime'] == VrlzBuiltinManifest.supportedRuntime) {
        if (archive.entries.length != 1) {
          throw const FormatException(
            'Builtin VRLZ must contain only manifest.json.',
          );
        }
        return VrlzPackage._builtin(VrlzBuiltinManifest.fromJson(json), source);
      }
      // Single-bundle packages (`scene`, `nes`, `retro`) fit <= 32 MiB.
      if (randomSource.length > maxBytes) {
        throw const FormatException('VRLZ package exceeds 32 MiB budget.');
      }
      final fullBytes = await randomSource.readRange(0, randomSource.length);
      return decode(fullBytes, source: source);
    } finally {
      if (!keepArchiveOpen) {
        await archive.close();
      }
    }
  }

  Future<void> close() async {
    await worldBundle?.close();
  }

  /// Creates a STORE-only v2 PBR/KTX2/meshopt/animation scene package.
  static Uint8List encodeSceneV2({
    required Uint8List sceneBytes,
    required String id,
    required String title,
    String description = '',
    List<String> capabilities = const ['scene.gltf2', 'scene.pbr'],
    List<double> cameraPosition = const [0, 1.6, 6],
    List<double> cameraTarget = const [0, 1, -6],
    Map<String, Object?> extensions = const {},
  }) => VrzBundle.encodeV2(
    sceneBytes: sceneBytes,
    id: id,
    title: title,
    description: description,
    capabilities: capabilities,
    cameraPosition: cameraPosition,
    cameraTarget: cameraTarget,
    extensions: extensions,
  );

  /// Small index only; JS/WASM/assets remain individually verified resources.
  static Uint8List encodeWebGame({required VrlzWebGameManifest manifest}) {
    final bytes = Uint8List.fromList(
      utf8.encode(jsonEncode(manifest.toJson())),
    );
    final encoded = writeVrzStoreZip({
      'manifest.json': bytes,
    }, VrlzWebGameManifest.maxIndexBytes);
    decode(encoded);
    return encoded;
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
    final metadata = Uint8List.fromList(
      utf8.encode(jsonEncode(manifest.toJson())),
    );
    final encoded = writeVrzStoreZip({'manifest.json': metadata}, maxBytes);
    decode(encoded);
    return encoded;
  }
}
