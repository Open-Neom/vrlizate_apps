import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:vrlizate_world/vrlizate_world.dart';

import 'vrlz_stream_archive.dart';
import 'vrlz_stream_source.dart';
import 'vrlz_world_manifest.dart';
import 'vrz_glb.dart';
import 'vrz_zip.dart';
import 'vrlw_audio_policy.dart';
import 'vrlw_motion_profile.dart';
import 'vrlw_lod_profile.dart';
import 'vrlw_texture_policy.dart';

/// A portable data-only experience. Renderers and Dart code belong to the host;
/// embedded worlds provide bounded placements, validated models and textures.
final class VrlzWorldBundle {
  VrlzWorldBundle._(
    this.manifest,
    this.manifestSha256,
    this._files,
    this._indices,
    this.source, [
    this._streamArchive,
  ]);
  static const maxBytes = 32 * 1024 * 1024;
  static const maxStreamArchiveBytes = 256 * 1024 * 1024;
  static const maxWorldChunks = 64;
  static const maxWorldResources = 8;
  static const maxExtendedWorldResources = 64;
  static const maxExtendedWorldUnpackedBytes = 32 * 1024 * 1024;
  // A separate, small PCM budget does not increase the model/texture budget.
  static const maxWorldAudioResources = 1;
  static const maxExtendedWorldAudioResources = 8;
  static const maxWorldBindings = 16;
  static const maxExtendedWorldBindings = 64;
  static const maxModelTriangles = 20000;
  static const maxExtendedModelTriangles = 60000;
  static const maxCellSizeMeters = 128;
  final VrlzWorldManifest manifest;
  final String manifestSha256;
  final Uri? source;
  final Map<String, Uint8List> _files;
  final Map<String, VrlwBundleIndex> _indices;
  final VrlzStreamArchive? _streamArchive;
  final Set<String> _verifiedStreamWorldAliases = <String>{};

  /// Whether this bundle streams worlds on demand from a [VrlzStreamArchive]
  /// without keeping all `.vrlw` binaries resident in heap memory.
  bool get isStreaming => _streamArchive != null;

  /// Peak unpacked resource bytes across any single world in this bundle.
  int get maxWorldResourceBytes {
    var peak = 0;
    for (final index in _indices.values) {
      var sum = 0;
      for (final resource in index.resources) {
        sum += resource.unpackedBytes;
      }
      if (sum > peak) peak = sum;
    }
    return peak;
  }

  /// Peak triangle ceiling implied by the active `vrlizate.worlds.v1` profile.
  int get worldModelTriangleBudget => manifest.hasExtendedProfile
      ? maxExtendedModelTriangles
      : maxModelTriangles;

  static bool isWorldFile(String name) =>
      RegExp(r'^world_[a-z][a-z0-9_-]{0,31}\.vrlw$').hasMatch(name);

  static bool hasRawVrlwMagic(Uint8List bytes) =>
      bytes.length >= VrlwBundleCodec.headerSize &&
      bytes[0] == 0x56 &&
      bytes[1] == 0x52 &&
      bytes[2] == 0x4C &&
      bytes[3] == 0x57 &&
      bytes[4] == 0x30 &&
      bytes[5] == 0x30 &&
      bytes[6] == 0x30 &&
      bytes[7] == 0x31;

  static VrlzWorldBundle fromRawVrlw(
    Uint8List bytes, {
    Uri? source,
    bool allowExtendedProfile = false,
  }) {
    if (bytes.length > maxBytes || bytes.length < VrlwBundleCodec.headerSize) {
      throw const FormatException('VRLW exceeds 32 MiB or is truncated.');
    }
    final header = VrlwBundleCodec.parseHeader(
      bytes.sublist(0, VrlwBundleCodec.headerSize),
    );
    if (header.totalLength != bytes.length) {
      throw const FormatException('VRLW total length mismatch.');
    }
    final index = VrlwBundleCodec.parseIndex(
      header,
      bytes.sublist(VrlwBundleCodec.headerSize, header.payloadOffset),
    );
    final fitsBase =
        _withinResourceBudget(index, extendedProfile: false) &&
        index.prototypeBindings.length <= maxWorldBindings;
    final fitsExtended =
        allowExtendedProfile &&
        _withinResourceBudget(index, extendedProfile: true) &&
        index.prototypeBindings.length <= maxExtendedWorldBindings;
    if (index.origin['type'] != 'local' ||
        index.cellSizeMeters > maxCellSizeMeters ||
        index.chunks.length > maxWorldChunks ||
        index.chunks.isEmpty ||
        (!fitsBase && !fitsExtended) ||
        index.resources.isEmpty ||
        index.prototypeBindings.isEmpty ||
        index.prototypeBindings.map((b) => b.prototypeId).toSet().length !=
            index.prototypeIds.length) {
      throw const FormatException('VRLW exceeds the portable worlds profile.');
    }
    final bindingIds = index.prototypeBindings
        .map((b) => b.prototypeId)
        .toSet();
    if (!bindingIds.containsAll(index.prototypeIds)) {
      throw const FormatException('Every prototype requires a model binding.');
    }
    final firstChunk = index.chunks.first;
    final spawnX = (firstChunk.x + 0.5) * index.cellSizeMeters;
    final spawnZ = (firstChunk.z + 0.5) * index.cellSizeMeters;
    final sha = crypto.sha256.convert(bytes).toString();
    final rawTitle = index.title
        .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ')
        .trim();
    final safeTitle = rawTitle.isEmpty
        ? index.id
        : (rawTitle.length > 96 ? rawTitle.substring(0, 96) : rawTitle);
    final rawRev = index.revision
        .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '')
        .trim();
    final safeRev = rawRev.isEmpty
        ? '1'
        : (rawRev.length > 64 ? rawRev.substring(0, 64) : rawRev);
    final hasKtx2 = index.resources.any((r) => r.type == 'texture.ktx2');
    final useExtendedCaps = !fitsBase || hasKtx2;
    final manifest = VrlzWorldManifest.fromJson(<String, dynamic>{
      'formatVersion': VrlzWorldManifest.supportedFormatVersion,
      'id': index.id,
      'title': safeTitle,
      'description': 'Mundo portatil .vrlw',
      'runtime': VrlzWorldManifest.runtime,
      'entrypoint': 'main',
      'capabilities': useExtendedCaps
          ? [
              'worlds.local',
              'worlds.pbr',
              if (hasKtx2) 'worlds.ktx2',
              'worlds.physics',
            ]
          : ['worlds.local'],
      'revision': safeRev,
      'worlds': [
        {
          'alias': 'main',
          'id': index.id,
          'file': 'world_main.vrlw',
          'sha256': sha,
          'indexSha256': index.indexSha256,
          // Raw places have no experience-level spawn. Start at standing eye
          // height, not on the ground plane where geometry clips the view.
          'spawn': [spawnX, 1.6, spawnZ],
          'yaw': 0.0,
        },
      ],
      'portals': const <Map<String, dynamic>>[],
    });
    final metadataBytes = utf8.encode(jsonEncode(manifest.toJson()));
    return VrlzWorldBundle._(
      manifest,
      crypto.sha256.convert(metadataBytes).toString(),
      {'main': Uint8List.fromList(bytes)},
      {'main': index},
      source,
    );
  }

  static VrlzWorldBundle decode(Uint8List bytes, {Uri? source}) {
    final files = readVrzZip(
      bytes,
      maxBytes,
      allowedFiles: const {'manifest.json'},
      maxEntries: VrlzWorldManifest.maxWorlds + 1,
      allowAdditionalFile: isWorldFile,
    );
    final metadata = files['manifest.json']!;
    final manifest = VrlzWorldManifest.fromJson(decodeVrzJson(metadata));
    final extended = manifest.hasExtendedProfile;
    final bindingLimit = extended ? maxExtendedWorldBindings : maxWorldBindings;
    if (files.length != manifest.worlds.length + 1 ||
        !manifest.worlds.every((world) => files.containsKey(world.file))) {
      throw const FormatException(
        'VRLZ worlds contains undeclared/missing files.',
      );
    }
    final stored = <String, Uint8List>{};
    final indices = <String, VrlwBundleIndex>{};
    for (final world in manifest.worlds) {
      final data = files[world.file]!;
      if (crypto.sha256.convert(data).toString() != world.sha256 ||
          data.length < VrlwBundleCodec.headerSize) {
        throw const FormatException('VRLZ world hash/length mismatch.');
      }
      final header = VrlwBundleCodec.parseHeader(
        data.sublist(0, VrlwBundleCodec.headerSize),
      );
      if (header.totalLength != data.length) {
        throw const FormatException('VRLW total length mismatch.');
      }
      final index = VrlwBundleCodec.parseIndex(
        header,
        data.sublist(VrlwBundleCodec.headerSize, header.payloadOffset),
      );
      if (index.indexSha256 != world.indexSha256 ||
          index.id != world.id ||
          index.origin['type'] != 'local' ||
          index.cellSizeMeters > maxCellSizeMeters ||
          index.chunks.length > maxWorldChunks ||
          index.chunks.isEmpty ||
          !_withinResourceBudget(index, extendedProfile: extended) ||
          index.resources.isEmpty ||
          index.prototypeBindings.length > bindingLimit ||
          index.prototypeBindings.isEmpty ||
          index.prototypeBindings.map((b) => b.prototypeId).toSet().length !=
              index.prototypeIds.length) {
        throw const FormatException(
          'VRLW exceeds the portable worlds profile.',
        );
      }
      final bindingIds = index.prototypeBindings
          .map((b) => b.prototypeId)
          .toSet();
      if (!bindingIds.containsAll(index.prototypeIds)) {
        throw const FormatException(
          'Every prototype requires a model binding.',
        );
      }
      // Own immutable representations. Never retain writable caller subviews.
      stored[world.alias] = Uint8List.fromList(data);
      indices[world.alias] = index;
    }
    void requireCell(String alias, List<double> point) {
      final index = indices[alias]!;
      if (index.chunkAt(
            (point[0] / index.cellSizeMeters).floor(),
            (point[2] / index.cellSizeMeters).floor(),
          ) ==
          null) {
        throw const FormatException('Spawn or portal lies outside its world.');
      }
    }

    for (final world in manifest.worlds) {
      requireCell(world.alias, world.spawn);
    }
    for (final portal in manifest.portals) {
      requireCell(portal.from, portal.position);
      requireCell(portal.to, portal.arrival);
    }
    return VrlzWorldBundle._(
      manifest,
      crypto.sha256.convert(metadata).toString(),
      stored,
      indices,
      source,
    );
  }

  /// The map is keyed by the exact manifest filenames, not aliases.
  static Uint8List encode(
    Map<String, dynamic> manifest,
    Map<String, Uint8List> worldFiles,
  ) {
    final checked = VrlzWorldManifest.fromJson(manifest);
    if (worldFiles.length != checked.worlds.length ||
        !checked.worlds.every((world) => worldFiles.containsKey(world.file))) {
      throw const FormatException('World file map does not match manifest.');
    }
    final metadata = utf8.encode(jsonEncode(checked.toJson()));
    var size = metadata.length;
    for (final bytes in worldFiles.values) {
      size += bytes.length;
    }
    if (size > maxBytes) throw const FormatException('VRLZ exceeds 32 MiB.');
    final bytes = writeVrzStoreZip(
      {
        'manifest.json': Uint8List.fromList(metadata),
        for (final world in checked.worlds) world.file: worldFiles[world.file]!,
      },
      maxBytes,
      maxEntries: VrlzWorldManifest.maxWorlds + 1,
    );
    decode(bytes);
    return bytes;
  }

  Uint8List encodeBundle() {
    if (_streamArchive != null) {
      throw StateError(
        'Streaming VrlzWorldBundle does not hold all world bytes in RAM.',
      );
    }
    return encode(manifest.toJson(), {
      for (final world in manifest.worlds) world.file: _files[world.alias]!,
    });
  }

  /// Returns an immutable copy of the `.vrlw` binary for [alias] on in-memory
  /// bundles. Streaming bundles should call [readWorldBytes] instead.
  Uint8List worldBytes(String alias) {
    final mem = _files[alias];
    if (mem == null) {
      throw StateError(
        'World "$alias" is streamed on demand; use readWorldBytes(alias).',
      );
    }
    return Uint8List.fromList(mem);
  }

  /// Reads the full `.vrlw` binary for [alias] (from memory or stream archive).
  Future<Uint8List> readWorldBytes(String alias) async {
    final mem = _files[alias];
    if (mem != null) return Uint8List.fromList(mem);
    final archive = _streamArchive;
    if (archive == null) {
      throw ArgumentError.value(alias, 'alias', 'Unknown world alias.');
    }
    final world = manifest.world(alias);
    await _ensureStreamWorldSha256Verified(world);
    return archive.readEntryBytes(world.file);
  }

  /// Opens a multi-world `.vrlz` v1 archive directly from an Android SAF
  /// `content://` URI via JNI (`ContentResolver.openFileDescriptor().detachFd()`)
  /// without copying or unpacking `.vrlw` payloads into RAM or app cache.
  static Future<VrlzWorldBundle> openAndroidSafUri(
    String contentUri, {
    int maxArchiveBytes = maxStreamArchiveBytes,
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

  /// Opens a multi-world `.vrlz` v1 archive over [randomSource] (such as a
  /// local file or Android SAF `fd:<n>/<name>` descriptor) without unpacking or
  /// loading `.vrlw` payloads into RAM: only `manifest.json` and each world's
  /// small `.vrlw` header+index slice are read up front.
  static Future<VrlzWorldBundle> openStream(
    VrlzRandomAccessSource randomSource, {
    Uri? source,
    bool ownsSource = true,
    int maxArchiveBytes = maxStreamArchiveBytes,
    int maxMemoryCacheBytes = VrlzStreamArchive.defaultMaxMemoryCacheBytes,
    int tempFileThresholdBytes =
        VrlzStreamArchive.defaultTempFileThresholdBytes,
  }) async {
    final archive = await VrlzStreamArchive.open(
      randomSource,
      ownsSource: ownsSource,
      maxArchiveBytes: maxArchiveBytes,
      maxEntries: VrlzWorldManifest.maxWorlds + 1,
      maxEntryUnpackedBytes: maxBytes,
      maxTotalUnpackedBytes: maxArchiveBytes,
      allowedFiles: const {'manifest.json'},
      allowAdditionalFile: isWorldFile,
      maxMemoryCacheBytes: maxMemoryCacheBytes,
      tempFileThresholdBytes: tempFileThresholdBytes,
    );
    try {
      final metadata = await archive.readEntryBytes('manifest.json');
      final manifest = VrlzWorldManifest.fromJson(decodeVrzJson(metadata));
      return await fromStreamArchive(
        archive,
        metadataBytes: metadata,
        manifest: manifest,
        source: source,
      );
    } catch (_) {
      await archive.close();
      rethrow;
    }
  }

  /// Internal helper shared with `VrlzPackage.openStream` so `manifest.json` is
  /// parsed once without re-opening the central directory.
  static Future<VrlzWorldBundle> fromStreamArchive(
    VrlzStreamArchive archive, {
    required Uint8List metadataBytes,
    required VrlzWorldManifest manifest,
    Uri? source,
  }) async {
    final extended = manifest.hasExtendedProfile;
    final bindingLimit = extended ? maxExtendedWorldBindings : maxWorldBindings;
    if (archive.entries.length != manifest.worlds.length + 1 ||
        !manifest.worlds.every((w) => archive.containsFile(w.file) && isWorldFile(w.file))) {
      throw const FormatException(
        'VRLZ worlds stream contains undeclared or missing world files.',
      );
    }

    final indices = <String, VrlwBundleIndex>{};
    for (final world in manifest.worlds) {
      final info = archive.entry(world.file)!;
      if (info.unpackedBytes < VrlwBundleCodec.headerSize ||
          info.unpackedBytes > maxBytes) {
        throw const FormatException('VRLW exceeds 32 MiB or is truncated.');
      }
      final slice = await archive.openEntryByteSource(world.file);
      late final VrlwBundleIndex index;
      try {
        final headerBytes = await slice.readRange(
          0,
          VrlwBundleCodec.headerSize,
        );
        final header = VrlwBundleCodec.parseHeader(headerBytes);
        if (header.totalLength != info.unpackedBytes) {
          throw const FormatException('VRLW total length mismatch.');
        }
        final indexBytes = await slice.readRange(
          VrlwBundleCodec.headerSize,
          header.payloadOffset - VrlwBundleCodec.headerSize,
        );
        index = VrlwBundleCodec.parseIndex(header, indexBytes);
      } finally {
        await slice.close();
      }

      if (index.indexSha256 != world.indexSha256 ||
          index.id != world.id ||
          index.origin['type'] != 'local' ||
          index.cellSizeMeters > maxCellSizeMeters ||
          index.chunks.length > maxWorldChunks ||
          index.chunks.isEmpty ||
          !_withinResourceBudget(index, extendedProfile: extended) ||
          index.resources.isEmpty ||
          index.prototypeBindings.length > bindingLimit ||
          index.prototypeBindings.isEmpty ||
          index.prototypeBindings.map((b) => b.prototypeId).toSet().length !=
              index.prototypeIds.length) {
        throw const FormatException(
          'VRLW exceeds the portable worlds profile.',
        );
      }
      final bindingIds = index.prototypeBindings
          .map((b) => b.prototypeId)
          .toSet();
      if (!bindingIds.containsAll(index.prototypeIds)) {
        throw const FormatException(
          'Every prototype requires a model binding.',
        );
      }
      indices[world.alias] = index;
    }

    void requireCell(String alias, List<double> point) {
      final index = indices[alias]!;
      if (index.chunkAt(
            (point[0] / index.cellSizeMeters).floor(),
            (point[2] / index.cellSizeMeters).floor(),
          ) ==
          null) {
        throw const FormatException('Spawn or portal lies outside its world.');
      }
    }

    for (final world in manifest.worlds) {
      requireCell(world.alias, world.spawn);
    }
    for (final portal in manifest.portals) {
      requireCell(portal.from, portal.position);
      requireCell(portal.to, portal.arrival);
    }

    return VrlzWorldBundle._(
      manifest,
      crypto.sha256.convert(metadataBytes).toString(),
      const <String, Uint8List>{},
      indices,
      source,
      archive,
    );
  }

  Future<void> _ensureStreamWorldSha256Verified(VrlzWorldEntry world) async {
    if (_verifiedStreamWorldAliases.contains(world.alias)) return;
    final archive = _streamArchive!;
    final byteSource = await archive.openEntryByteSource(
      world.file,
      verifyStoreCrcOnOpen: true,
    );
    try {
      final total = byteSource.length ?? 0;
      const stepBytes = 256 * 1024;
      late crypto.Digest digest;
      final chunked = crypto.sha256.startChunkedConversion(
        _SingleDigestSink((d) => digest = d),
      );
      var offset = 0;
      while (offset < total) {
        final len = math.min(stepBytes, total - offset);
        final block = await byteSource.readRange(offset, len);
        chunked.add(block);
        offset += len;
      }
      chunked.close();
      if (digest.toString() != world.sha256) {
        throw const FormatException('VRLZ streamed world SHA-256 mismatch.');
      }
      _verifiedStreamWorldAliases.add(world.alias);
    } finally {
      await byteSource.close();
    }
  }

  Future<void> close() async {
    await _streamArchive?.close();
  }

  /// Validates all embedded GLB models across all worlds and returns the peak
  /// per-world VRAM and model triangle count for creator budget admission.
  ({int peakVramBytes, int maxModelTriangles}) inspectBudgetMetrics() {
    final extended = manifest.hasExtendedProfile;
    final allowKtx2 = manifest.allowsKtx2Textures;
    final triCap = extended ? maxExtendedModelTriangles : maxModelTriangles;
    var peakWorldVram = 0;
    var peakTriangles = 0;
    for (final world in manifest.worlds) {
      final index = _indices[world.alias]!;
      final data = _files[world.alias]!;
      for (final resource in index.resources) {
        VrlwTexturePolicy.validateDecoder(
          resource.type,
          allowKtx2Textures: allowKtx2,
        );
      }
      var worldVram = 0;
      final resources = <String, Uint8List>{};
      for (final resource in index.resources) {
        final start = index.header.payloadOffset + resource.offset;
        final decoded = VrlwBundleCodec.decodeResource(
          index,
          resource,
          Uint8List.sublistView(data, start, start + resource.packedBytes),
        );
        if (resource.type == 'model.glb') {
          final stats = inspectVrzGlbStats(
            decoded,
            maxSubmittedTriangles: triCap,
            allowEmbeddedBaseColorTextures: true,
            allowExtendedGraphics: extended,
          );
          worldVram += stats.estimatedVramBytes + decoded.length;
          peakTriangles = math.max(peakTriangles, stats.submittedTriangles);
        } else if (resource.type == 'texture.ktx2') {
          final info = VrlwTexturePolicy.validateKtx2Payload(
            decoded,
            declaredWidth: resource.width,
            declaredHeight: resource.height,
          );
          worldVram += info.estimatedGpuVramBytes;
        } else if (resource.type.startsWith('audio.')) {
          VrlwAudioPolicy.validate(decoded);
        } else {
          final w = resource.width;
          final h = resource.height;
          worldVram += (w != null && h != null) ? w * h * 4 : decoded.length;
        }
        resources[resource.id] = decoded;
      }
      VrlwLodProfile.validate(index, resources, allowMovingLod: extended);
      VrlwMotionProfile.validate(index, resources);
      peakWorldVram = math.max(peakWorldVram, worldVram);
    }
    return (
      peakVramBytes: peakWorldVram,
      maxModelTriangles: peakTriangles,
    );
  }

  static bool _withinResourceBudget(
    VrlwBundleIndex index, {
    required bool extendedProfile,
  }) {
    final audio = index.resources
        .where((r) => r.type.startsWith('audio.'))
        .toList();
    final nonAudio = index.resources
        .where((r) => !r.type.startsWith('audio.'))
        .toList();
    final maxRes = extendedProfile
        ? maxExtendedWorldResources
        : maxWorldResources;
    final maxAudio = extendedProfile
        ? maxExtendedWorldAudioResources
        : maxWorldAudioResources;
    var unpackedNonAudio = 0;
    for (final resource in nonAudio) {
      unpackedNonAudio += resource.unpackedBytes;
    }
    return nonAudio.length <= maxRes &&
        (!extendedProfile || unpackedNonAudio <= maxExtendedWorldUnpackedBytes) &&
        audio.length <= maxAudio &&
        audio.every(
          (r) =>
              r.type == 'audio.wav' &&
              r.unpackedBytes <= VrlwAudioPolicy.maxBytes,
        );
  }

  /// The full model profile is validated before any prototype is registered or
  /// any GPU resource is created. Region expansion remains demand-driven.
  Future<VrlzPreparedWorld> openWorld(String alias) async {
    final extended = manifest.hasExtendedProfile;
    final allowKtx2 = manifest.allowsKtx2Textures;
    final world = manifest.world(alias);
    final index = _indices[alias]!;
    for (final resource in index.resources) {
      VrlwTexturePolicy.validateDecoder(
        resource.type,
        allowKtx2Textures: allowKtx2,
      );
    }

    final streamArchive = _streamArchive;
    if (streamArchive != null) {
      await _ensureStreamWorldSha256Verified(world);
      final worldSource = await streamArchive.openEntryByteSource(world.file);
      try {
        final resources = <String, Uint8List>{};
        for (final resource in index.resources) {
          final start = index.header.payloadOffset + resource.offset;
          final packedSlice = await worldSource.readRange(
            start,
            resource.packedBytes,
          );
          final decoded = VrlwBundleCodec.decodeResource(
            index,
            resource,
            packedSlice,
          );
          if (resource.type == 'model.glb') {
            validateVrzGlb(
              decoded,
              maxSubmittedTriangles: extended
                  ? maxExtendedModelTriangles
                  : maxModelTriangles,
              allowEmbeddedBaseColorTextures: true,
              allowExtendedGraphics: extended,
            );
          } else if (resource.type == 'texture.ktx2') {
            VrlwTexturePolicy.validateKtx2Payload(
              decoded,
              declaredWidth: resource.width,
              declaredHeight: resource.height,
            );
          } else if (resource.type.startsWith('audio.')) {
            VrlwAudioPolicy.validate(decoded);
          }
          resources[resource.id] = decoded;
        }
        VrlwLodProfile.validate(index, resources, allowMovingLod: extended);
        VrlwMotionProfile.validate(index, resources);
        final reader = await VrlwPlaceReader.open(
          worldSource,
          registeredPrototypeIds: index.prototypeBindings
              .map((binding) => binding.prototypeId)
              .toSet(),
          expectedIndexSha256: world.indexSha256,
        );
        return VrlzPreparedWorld(
          reader,
          Map.unmodifiable(resources),
          hasExtendedProfile: extended,
          allowsKtx2Textures: allowKtx2,
        );
      } catch (_) {
        await worldSource.close();
        rethrow;
      }
    }

    final data = _files[alias]!;
    final resources = <String, Uint8List>{};
    for (final resource in index.resources) {
      final start = index.header.payloadOffset + resource.offset;
      final decoded = VrlwBundleCodec.decodeResource(
        index,
        resource,
        Uint8List.sublistView(data, start, start + resource.packedBytes),
      );
      if (resource.type == 'model.glb') {
        validateVrzGlb(
          decoded,
          maxSubmittedTriangles: extended
              ? maxExtendedModelTriangles
              : maxModelTriangles,
          allowEmbeddedBaseColorTextures: true,
          allowExtendedGraphics: extended,
        );
      } else if (resource.type == 'texture.ktx2') {
        VrlwTexturePolicy.validateKtx2Payload(
          decoded,
          declaredWidth: resource.width,
          declaredHeight: resource.height,
        );
      } else if (resource.type.startsWith('audio.')) {
        VrlwAudioPolicy.validate(decoded);
      }
      resources[resource.id] = decoded;
    }
    VrlwLodProfile.validate(index, resources, allowMovingLod: extended);
    VrlwMotionProfile.validate(index, resources);
    final source = VrlwMemorySource(data);
    try {
      final reader = await VrlwPlaceReader.open(
        source,
        registeredPrototypeIds: index.prototypeBindings
            .map((binding) => binding.prototypeId)
            .toSet(),
        expectedIndexSha256: world.indexSha256,
      );
      return VrlzPreparedWorld(
        reader,
        Map.unmodifiable(resources),
        hasExtendedProfile: extended,
        allowsKtx2Textures: allowKtx2,
      );
    } catch (_) {
      await source.close();
      rethrow;
    }
  }

  bool containsPosition(String alias, List<double> position) {
    final index = _indices[alias];
    if (index == null) return false;
    return index.chunkAt(
          (position[0] / index.cellSizeMeters).floor(),
          (position[2] / index.cellSizeMeters).floor(),
        ) !=
        null;
  }
}

final class _SingleDigestSink implements Sink<crypto.Digest> {
  _SingleDigestSink(this._onDigest);
  final void Function(crypto.Digest) _onDigest;

  @override
  void add(crypto.Digest data) => _onDigest(data);

  @override
  void close() {}
}

final class VrlzPreparedWorld {
  const VrlzPreparedWorld(
    this.reader,
    this.resources, {
    this.hasExtendedProfile = false,
    this.allowsKtx2Textures = false,
  });
  final VrlwPlaceReader reader;
  final Map<String, Uint8List> resources;
  final bool hasExtendedProfile;
  final bool allowsKtx2Textures;
}
