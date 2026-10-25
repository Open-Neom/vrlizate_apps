import 'dart:convert';
import 'dart:typed_data';

import 'package:vrlizate_world/vrlizate_world.dart';

/// Runs after the general GLB validator and before any native import/GPU work.
/// The initial portable-motion profile only accepts a named mesh leaf directly
/// in the active scene. No hierarchy or transform ambiguity is downloaded.
abstract final class VrlwMotionProfile {
  static void validate(
    VrlwBundleIndex index,
    Map<String, Uint8List> resources,
  ) {
    final documents = <String, Map<String, dynamic>>{};
    for (final motion in index.motions) {
      final binding = index.prototypeBindings.singleWhere(
        (b) => b.prototypeId == motion.prototypeId,
      );
      final doc = documents.putIfAbsent(binding.model, () {
        final bytes = resources[binding.model]!;
        final length = ByteData.sublistView(bytes).getUint32(12, Endian.little);
        return jsonDecode(
              utf8.decode(Uint8List.sublistView(bytes, 20, 20 + length)),
            )
            as Map<String, dynamic>;
      });
      final nodes = doc['nodes'] as List;
      final matches = <int>[
        for (var n = 0; n < nodes.length; n++)
          if ((nodes[n] as Map)['name'] == motion.node) n,
      ];
      if (matches.length != 1) {
        throw const FormatException(
          'Motion requires exactly one named GLB node.',
        );
      }
      final node = nodes[matches.single] as Map;
      final scene = (doc['scenes'] as List)[doc['scene'] as int? ?? 0] as Map;
      if (!(scene['nodes'] as List).contains(matches.single) ||
          node['mesh'] is! int ||
          (node['children'] as List? ?? const []).isNotEmpty ||
          [
            'matrix',
            'translation',
            'rotation',
            'scale',
          ].any(node.containsKey)) {
        throw const FormatException(
          'Motion requires an identity mesh leaf directly in the GLB scene.',
        );
      }
    }
  }
}
