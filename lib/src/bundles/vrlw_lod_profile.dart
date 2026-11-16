import 'dart:typed_data';

import 'package:vrlizate_world/vrlizate_world.dart';

import 'vrz_glb.dart';

/// Checks the portable LOD subset after [validateVrzGlb] and before GPU import.
/// All levels share one resource and remain under its total storage/triangle
/// limits; selecting a level never grants another budget.
abstract final class VrlwLodProfile {
  static void validate(
    VrlwBundleIndex index,
    Map<String, Uint8List> resources, {
    bool allowMovingLod = false,
  }) {
    final lodModels = {
      for (final binding in index.prototypeBindings)
        if (binding.lods.isNotEmpty) binding.model,
    };
    final documents = <String, Map<String, Object?>>{};
    for (final binding in index.prototypeBindings) {
      if (binding.lods.isEmpty) {
        if (lodModels.contains(binding.model)) {
          _fail('A LOD model cannot also be bound as a complete legacy model.');
        }
        continue;
      }
      if (!allowMovingLod &&
          index.motions.any((m) => m.prototypeId == binding.prototypeId)) {
        _fail('LOD currently requires a static prototype without motion.');
      }
      final document = documents.putIfAbsent(binding.model, () {
        final bytes = resources[binding.model]!;
        final length = ByteData.sublistView(bytes).getUint32(12, Endian.little);
        return decodeVrzJson(Uint8List.sublistView(bytes, 20, 20 + length));
      });
      final nodes = (document['nodes'] as List).cast<Map>();
      final scene =
          (document['scenes'] as List)[document['scene'] as int? ?? 0] as Map;
      final roots = (scene['nodes'] as List).cast<int>().toSet();
      final selected = <int>[];
      for (final level in binding.lods) {
        final matches = [
          for (var i = 0; i < nodes.length; i++)
            if (nodes[i]['name'] == level.node) i,
        ];
        if (matches.length != 1 || !roots.contains(matches.single)) {
          _fail(
            'Each LOD requires one uniquely named root in the active GLB scene.',
          );
        }
        final root = nodes[matches.single];
        if ([
          'matrix',
          'translation',
          'rotation',
          'scale',
        ].any(root.containsKey)) {
          _fail('LOD roots must have implicit identity transforms.');
        }
        selected.add(matches.single);
      }
      if (selected.length != roots.length ||
          selected.toSet().length != roots.length) {
        _fail('LOD roots must cover the complete active GLB scene.');
      }
      final meshes = (document['meshes'] as List).cast<Map>();
      final accessors = (document['accessors'] as List).cast<Map>();
      final visited = <int>{};
      ({int triangles, int primitives}) countsAt(int nodeIndex) {
        if (!visited.add(nodeIndex)) _fail('LOD subtrees must be disjoint.');
        final node = nodes[nodeIndex];
        var count = 0;
        var primitives = 0;
        if (node['mesh'] case final int meshIndex) {
          for (final primitive
              in (meshes[meshIndex]['primitives'] as List).cast<Map>()) {
            final accessor =
                primitive['indices'] ??
                (primitive['attributes'] as Map)['POSITION'];
            count += (accessors[accessor as int]['count'] as int) ~/ 3;
            primitives++;
          }
        }
        for (final child
            in (node['children'] as List? ?? const []).cast<int>()) {
          final sub = countsAt(child);
          count += sub.triangles;
          primitives += sub.primitives;
        }
        return (triangles: count, primitives: primitives);
      }

      int? previousTriangles;
      int? previousPrimitives;
      for (final root in selected) {
        final count = countsAt(root);
        if (count.triangles <= 0 ||
            (previousTriangles != null &&
                count.triangles >= previousTriangles)) {
          _fail(
            'LOD levels must be nonempty with strictly decreasing triangles.',
          );
        }
        if (previousPrimitives != null &&
            count.primitives > previousPrimitives) {
          _fail('LOD primitive counts must not increase with distance.');
        }
        previousTriangles = count.triangles;
        previousPrimitives = count.primitives;
      }
    }
  }

  static Never _fail(String reason) =>
      throw FormatException('VRLW LOD: $reason');
}
