import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_apps/vrlizate_apps.dart';

void main() {
  group('VrSpatialMiniAppDescriptor & VrSpatialMiniAppRegistry', () {
    test('registers built-in and developer mini-apps and filters by category and mode', () {
      final registry = VrSpatialMiniAppRegistry.withBuiltIns();
      expect(registry.builtInApps.length, 3);
      expect(registry.developerApps, isEmpty);

      const devApp = VrSpatialMiniAppDescriptor(
        id: 'org.dev.sketchpad_3d',
        title: 'Sketchpad 3D',
        subtitle: 'Spatial volumetric drawing canvas',
        category: VrMiniAppCategory.creativity,
        version: '1.2.0',
        supportsVisor: true,
        supportsHandheld: false,
        defaultPlacementDistanceMeters: 2.2,
      );

      expect(devApp.isValid, isTrue);
      expect(
        VrSpatialMiniAppDescriptor.fromJson(devApp.toJson()),
        equals(devApp),
      );

      registry.register(devApp);
      expect(registry.findById(devApp.id), equals(devApp));
      expect(registry.isBuiltIn(devApp.id), isFalse);
      expect(registry.developerApps, <VrSpatialMiniAppDescriptor>[devApp]);

      final creativityApps = registry.filter(
        category: VrMiniAppCategory.creativity,
      );
      expect(creativityApps, <VrSpatialMiniAppDescriptor>[devApp]);

      final handheldApps = registry.filter(requiresHandheld: true);
      expect(handheldApps.contains(devApp), isFalse);
      expect(handheldApps.length, 3);

      expect(registry.unregister(devApp.id), isTrue);
      expect(registry.findById(devApp.id), isNull);
    });

    test('rejects invalid mini-app descriptors', () {
      final registry = VrSpatialMiniAppRegistry();
      const invalidApp = VrSpatialMiniAppDescriptor(
        id: '',
        title: 'Broken',
        subtitle: 'No id',
        category: VrMiniAppCategory.utilities,
      );
      expect(invalidApp.isValid, isFalse);
      expect(() => registry.register(invalidApp), throwsArgumentError);
    });
  });

  group('VrPackageIntegrityVerifier', () {
    test('computes deterministic FNV-1a and CRC32 and checks bundle signatures', () {
      final vrlzBytes = <int>[0x50, 0x4B, 0x03, 0x04, 0x01, 0x02, 0x03, 0x04];
      final vrlwBytes = <int>[0x56, 0x52, 0x4C, 0x57, 0x00, 0x01, 0x00, 0x00];
      final invalidBytes = <int>[0x00, 0x01, 0x02, 0x03];

      expect(VrPackageIntegrityVerifier.hasVrlzZipSignature(vrlzBytes), isTrue);
      expect(VrPackageIntegrityVerifier.hasVrlwMagicSignature(vrlzBytes), isFalse);
      expect(VrPackageIntegrityVerifier.hasVrlwMagicSignature(vrlwBytes), isTrue);
      expect(
        VrPackageIntegrityVerifier.hasRecognizedBundleSignature(invalidBytes),
        isFalse,
      );

      final crc = VrPackageIntegrityVerifier.computeCrc32(vrlzBytes);
      final fnv = VrPackageIntegrityVerifier.computeFnv1a32(vrlzBytes);
      expect(VrPackageIntegrityVerifier.computeCrc32Hex(vrlzBytes).length, 8);
      expect(VrPackageIntegrityVerifier.computeFnv1a32Hex(vrlzBytes).length, 8);

      expect(
        VrPackageIntegrityVerifier.verifyBundle(
          vrlzBytes,
          expectedCrc32: crc,
          expectedFnv1a32: fnv,
          requireVrlzSignature: true,
        ),
        isTrue,
      );
      expect(
        VrPackageIntegrityVerifier.verifyBundle(
          vrlzBytes,
          expectedCrc32: crc ^ 1,
          requireVrlzSignature: true,
        ),
        isFalse,
      );
      expect(
        VrPackageIntegrityVerifier.verifyBundle(
          vrlwBytes,
          requireVrlwSignature: true,
        ),
        isTrue,
      );
    });
  });
}
