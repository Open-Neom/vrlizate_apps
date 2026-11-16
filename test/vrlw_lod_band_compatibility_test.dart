import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_apps/src/viewer/vrlw_lod_selector.dart';

void main() {
  test(
    'portable exact thresholds and multi-band jumps retain their semantics',
    () {
      final policy = VrlwLodPolicy(
        minDistancesMeters: const [0, 18, 42],
        bounds: VrlwLodBounds(
          minX: -1,
          minY: 0,
          minZ: -1,
          maxX: 1,
          maxY: 2,
          maxZ: 1,
        ),
      );
      for (final (previous, distance, expected) in <(int?, double, int)>[
        (null, 17.999, 0),
        (null, 18, 1),
        (null, 42, 2),
        (0, 19.999, 0),
        (0, 20, 1),
        (1, 16, 1),
        (1, 15.999, 0),
        (1, 43.999, 1),
        (1, 44, 2),
        (2, 40, 2),
        (2, 39.999, 1),
        (0, 1000, 2),
        (2, 0, 0),
      ]) {
        expect(
          policy.levelAtDistance(distance, previousLevel: previous),
          expected,
          reason: 'previous=$previous distance=$distance',
        );
      }
      // The portable contract remains stricter than a generic distance band.
      expect(
        () => policy.levelAtDistance(double.infinity),
        throwsArgumentError,
      );
    },
  );
}
