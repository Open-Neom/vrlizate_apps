import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Hashes a transient extracted geometry snapshot without retaining its arrays.
/// All rendered streams participate; equal positions alone cannot establish
/// equal shading. Absent streams and present empty streams remain distinct.
String vrlwGeometryFingerprint({
  required int vertexCount,
  required int primitiveType,
  required bool sourceWindingFlipped,
  required Float32List positions,
  Float32List? normals,
  Float32List? texCoords,
  Float32List? texCoords1,
  Float32List? colors,
  Float32List? tangents,
  List<int>? indices,
  Map<String, ({int components, Float32List data})> customAttributes = const {},
}) {
  final hash = _Fingerprint();
  hash.text('VRLW.static.geometry.1');
  hash.integer(vertexCount);
  hash.integer(primitiveType);
  hash.integer(sourceWindingFlipped ? 1 : 0);
  for (final stream in [
    positions,
    normals,
    texCoords,
    texCoords1,
    colors,
    tangents,
  ]) {
    hash.data(stream);
  }
  hash.integer(indices == null ? -1 : indices.length);
  if (indices != null) {
    // Normalize 16/32-bit storage without making another full index snapshot.
    final chunk = Uint32List(256);
    for (var offset = 0; offset < indices.length; offset += chunk.length) {
      final remaining = indices.length - offset;
      final count = remaining < chunk.length ? remaining : chunk.length;
      for (var i = 0; i < count; i++) {
        chunk[i] = indices[offset + i];
      }
      hash.bytes(Uint8List.view(chunk.buffer, 0, count * 4));
    }
  }
  final names = customAttributes.keys.toList()..sort();
  hash.integer(names.length);
  for (final name in names) {
    final attribute = customAttributes[name]!;
    hash.text(name);
    hash.integer(attribute.components);
    hash.data(attribute.data);
  }
  return hash.finish();
}

/// Import-only sharing for static parts within ONE prototype's LOD levels.
/// Material/shadow identity and the exact authored matrix also have to match.
/// The caller must exclude motion, skinning, morphs and mutable geometry.
///
/// Repeated equal parts in one level keep their multiplicity. Corresponding
/// occurrences in another level share a batch, so selecting a level never
/// inserts the same part fewer times than the original model required.
final class VrlwStaticPartPool<T> {
  final _parts = <_PartKey, List<T>>{};
  final _occurrencesByLevel = <int, Map<_PartKey, int>>{};

  T resolve({
    required int level,
    required String geometryFingerprint,
    required TypedData transform,
    required Object material,
    required Object shadowMode,
    required T Function() create,
  }) {
    final hash = _Fingerprint()
      ..text('VRLW.static.part.1')
      ..text(geometryFingerprint)
      ..data(transform);
    final key = _PartKey(hash.finish(), material, shadowMode);
    final occurrences = _occurrencesByLevel.putIfAbsent(level, () => {});
    final occurrence = occurrences[key] ?? 0;
    occurrences[key] = occurrence + 1;
    final parts = _parts.putIfAbsent(key, () => []);
    if (occurrence == parts.length) parts.add(create());
    return parts[occurrence];
  }
}

final class _PartKey {
  _PartKey(this.fingerprint, this.material, this.shadowMode);
  final String fingerprint;
  final Object material, shadowMode;

  @override
  bool operator ==(Object other) =>
      other is _PartKey &&
      fingerprint == other.fingerprint &&
      identical(material, other.material) &&
      identical(shadowMode, other.shadowMode);

  @override
  int get hashCode => Object.hash(
    fingerprint,
    identityHashCode(material),
    identityHashCode(shadowMode),
  );
}

final class _DigestSink implements Sink<Digest> {
  late Digest digest;
  @override
  void add(Digest data) => digest = data;
  @override
  void close() {}
}

final class _Fingerprint {
  _Fingerprint() {
    _sink = sha256.startChunkedConversion(_result);
  }
  final _result = _DigestSink();
  late final ByteConversionSink _sink;
  final _integer = ByteData(8);

  void integer(int value) {
    _integer.setInt64(0, value, Endian.little);
    _sink.add(_integer.buffer.asUint8List());
  }

  void bytes(Uint8List value) => _sink.add(value);

  void text(String value) {
    final encoded = utf8.encode(value);
    integer(encoded.length);
    _sink.add(encoded);
  }

  void data(TypedData? value) {
    integer(value?.lengthInBytes ?? -1);
    if (value != null) {
      _sink.add(
        Uint8List.view(value.buffer, value.offsetInBytes, value.lengthInBytes),
      );
    }
  }

  String finish() {
    _sink.close();
    return _result.digest.toString();
  }
}
