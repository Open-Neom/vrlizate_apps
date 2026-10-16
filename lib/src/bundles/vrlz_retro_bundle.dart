import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'vrlz_retro_level.dart';
import 'vrlz_retro_manifest.dart';
import 'vrz_glb.dart' show decodeVrzJson;
import 'vrz_zip.dart';

/// Portable level data for an explicitly supported, host-owned game runtime.
/// It contains no Dart bytecode, ROM, native library or external asset URLs.
final class VrlzRetroBundle {
  const VrlzRetroBundle._(this.manifest, this.level, this.source);
  static const maxBytes = 256 * 1024;
  final VrlzRetroManifest manifest;
  final VrlzRetroLevel level;
  final Uri? source;

  static VrlzRetroBundle decode(Uint8List bytes, {Uri? source}) {
    final files = readVrzZip(
      bytes,
      maxBytes,
      allowedFiles: const {'manifest.json', 'level.json'},
    );
    final manifest = VrlzRetroManifest.fromJson(
      decodeVrzJson(files['manifest.json']!),
    );
    final payload = files['level.json']!;
    if (sha256.convert(payload).toString() != manifest.levelSha256) {
      throw const FormatException(
        'level.json does not match the manifest SHA-256.',
      );
    }
    return VrlzRetroBundle._(
      manifest,
      VrlzRetroLevel.fromJson(decodeVrzJson(payload)),
      source,
    );
  }

  static Uint8List encode({
    required VrlzRetroLevel level,
    required String id,
    required String title,
    String description = '',
    required String license,
  }) {
    final payload = utf8.encode(jsonEncode(level.toJson()));
    final manifest = VrlzRetroManifest.fromJson({
      'formatVersion': VrlzRetroManifest.supportedFormatVersion,
      'id': id,
      'title': title,
      'description': description,
      'runtime': VrlzRetroManifest.supportedRuntime,
      'entrypoint': 'level.json',
      'capabilities': [VrlzRetroManifest.supportedCapability],
      'sha256': {'level.json': sha256.convert(payload).toString()},
      'license': license,
    });
    final metadata = utf8.encode(jsonEncode(manifest.toJson()));
    final archive = Archive()
      ..add(ArchiveFile.noCompress('manifest.json', metadata.length, metadata))
      ..add(ArchiveFile.noCompress('level.json', payload.length, payload));
    final encoded = ZipEncoder().encodeBytes(
      archive,
      modified: DateTime.utc(2000),
    );
    decode(encoded);
    return encoded;
  }
}
