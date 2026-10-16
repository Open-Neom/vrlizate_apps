import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:vrlizate_world/vrlizate_world.dart';

import 'vrlz_world_manifest.dart';
import 'vrz_glb.dart';
import 'vrz_zip.dart';

/// A portable data-only experience. Renderers and Dart code belong to the host;
/// embedded worlds provide bounded placements, validated models and textures.
final class VrlzWorldBundle {
  VrlzWorldBundle._(
    this.manifest,
    this.manifestSha256,
    this._files,
    this._indices,
    this.source,
  );
  static const maxBytes = 32 * 1024 * 1024;
  static const maxWorldChunks = 64;
  static const maxWorldResources = 8;
  static const maxWorldBindings = 16;
  static const maxModelTriangles = 20000;
  static const maxCellSizeMeters = 128;
  final VrlzWorldManifest manifest;
  final String manifestSha256;
  final Uri? source;
  final Map<String, Uint8List> _files;
  final Map<String, VrlwBundleIndex> _indices;

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

  static VrlzWorldBundle fromRawVrlw(Uint8List bytes, {Uri? source}) {
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
    if (index.origin['type'] != 'local' ||
        index.cellSizeMeters > maxCellSizeMeters ||
        index.chunks.length > maxWorldChunks ||
        index.chunks.isEmpty ||
        index.resources.length > maxWorldResources ||
        index.resources.isEmpty ||
        index.prototypeBindings.length > maxWorldBindings ||
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
    final rawRev = '${index.revision}'
        .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '')
        .trim();
    final safeRev = rawRev.isEmpty
        ? '1'
        : (rawRev.length > 64 ? rawRev.substring(0, 64) : rawRev);
    final manifest = VrlzWorldManifest.fromJson(<String, dynamic>{
      'formatVersion': 1,
      'id': index.id,
      'title': safeTitle,
      'description': 'Mundo portatil .vrlw',
      'runtime': VrlzWorldManifest.runtime,
      'entrypoint': 'main',
      'capabilities': ['worlds.local'],
      'revision': safeRev,
      'worlds': [
        {
          'alias': 'main',
          'id': index.id,
          'file': 'world_main.vrlw',
          'sha256': sha,
          'indexSha256': index.indexSha256,
          'spawn': [spawnX, 0.0, spawnZ],
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
      maxEntries: 9,
      allowAdditionalFile: isWorldFile,
    );
    final metadata = files['manifest.json']!;
    final manifest = VrlzWorldManifest.fromJson(decodeVrzJson(metadata));
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
          index.resources.length > maxWorldResources ||
          index.resources.isEmpty ||
          index.prototypeBindings.length > maxWorldBindings ||
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
    final bytes = writeVrzStoreZip({
      'manifest.json': Uint8List.fromList(metadata),
      for (final world in checked.worlds) world.file: worldFiles[world.file]!,
    }, maxBytes);
    decode(bytes);
    return bytes;
  }

  Uint8List encodeBundle() => encode(manifest.toJson(), {
    for (final world in manifest.worlds) world.file: _files[world.alias]!,
  });

  /// Returns an immutable copy of the `.vrlw` binary for [alias].
  Uint8List worldBytes(String alias) => Uint8List.fromList(_files[alias]!);

  /// The full model profile is validated before any prototype is registered or
  /// any GPU resource is created. Region expansion remains demand-driven.
  Future<VrlzPreparedWorld> openWorld(String alias) async {
    final world = manifest.world(alias);
    final index = _indices[alias]!;
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
        validateVrzGlb(decoded, maxSubmittedTriangles: maxModelTriangles);
      }
      resources[resource.id] = decoded;
    }
    final source = VrlwMemorySource(data);
    try {
      final reader = await VrlwPlaceReader.open(
        source,
        registeredPrototypeIds: index.prototypeBindings
            .map((binding) => binding.prototypeId)
            .toSet(),
        expectedIndexSha256: world.indexSha256,
      );
      return VrlzPreparedWorld(reader, Map.unmodifiable(resources));
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

final class VrlzPreparedWorld {
  const VrlzPreparedWorld(this.reader, this.resources);
  final VrlwPlaceReader reader;
  final Map<String, Uint8List> resources;
}
