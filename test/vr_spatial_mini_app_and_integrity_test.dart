import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_apps/vrlizate_apps.dart';
import 'package:vrlizate_world/vrlizate_world.dart';

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
    test(
      'distinguishes header-only verifySignatureAndChecksum from full structural verifyBundle on .vrlz and .vrlw (A10)',
      () {
        final bareZipHeader = Uint8List.fromList(const <int>[
          0x50,
          0x4B,
          0x03,
          0x04,
        ]);
        final bareVrlwHeader = Uint8List.fromList(const <int>[
          0x56,
          0x52,
          0x4C,
          0x57,
        ]);
        final invalidBytes = <int>[0x00, 0x01, 0x02, 0x03];

        expect(
          VrPackageIntegrityVerifier.hasVrlzZipSignature(bareZipHeader),
          isTrue,
        );
        expect(
          VrPackageIntegrityVerifier.hasVrlwMagicSignature(bareZipHeader),
          isFalse,
        );
        expect(
          VrPackageIntegrityVerifier.hasVrlwMagicSignature(bareVrlwHeader),
          isTrue,
        );
        expect(
          VrPackageIntegrityVerifier.hasRecognizedBundleSignature(invalidBytes),
          isFalse,
        );

        // Header-only preflight accepts magic prefixes + matching checksums...
        final headerCrc = VrPackageIntegrityVerifier.computeCrc32(bareZipHeader);
        final headerFnv =
            VrPackageIntegrityVerifier.computeFnv1a32(bareZipHeader);
        expect(
          VrPackageIntegrityVerifier.computeCrc32Hex(bareZipHeader).length,
          8,
        );
        expect(
          VrPackageIntegrityVerifier.computeFnv1a32Hex(bareZipHeader).length,
          8,
        );
        expect(
          VrPackageIntegrityVerifier.verifySignatureAndChecksum(
            bareZipHeader,
            expectedCrc32: headerCrc,
            expectedFnv1a32: headerFnv,
            requireVrlzSignature: true,
          ),
          isTrue,
        );
        expect(
          VrPackageIntegrityVerifier.verifySignatureAndChecksum(
            bareZipHeader,
            expectedCrc32: headerCrc ^ 1,
            requireVrlzSignature: true,
          ),
          isFalse,
        );

        // ...whereas full verifyBundle / validateBundleOrThrow REJECT bare 4-byte headers!
        expect(VrPackageIntegrityVerifier.verifyBundle(bareZipHeader), isFalse);
        expect(VrPackageIntegrityVerifier.verifyBundle(bareVrlwHeader), isFalse);
        expect(
          () => VrPackageIntegrityVerifier.validateBundleOrThrow(bareZipHeader),
          throwsFormatException,
        );
        expect(
          () => VrPackageIntegrityVerifier.validateBundleOrThrow(bareVrlwHeader),
          throwsFormatException,
        );

        // Valid encoded .vrlz package passes full structural + digest verification.
        final validVrlz = VrlzPackage.encodeBuiltin(
          id: 'org.vrlizate.test.demo',
          title: 'Demo Builtin',
          demoId: 'grove',
        );
        final vrlzCrc = VrPackageIntegrityVerifier.computeCrc32(validVrlz);
        final vrlzFnv = VrPackageIntegrityVerifier.computeFnv1a32(validVrlz);
        final vrlzSha = VrPackageIntegrityVerifier.computeSha256Hex(validVrlz);
        expect(
          VrPackageIntegrityVerifier.verifyBundle(
            validVrlz,
            expectedCrc32: vrlzCrc,
            expectedFnv1a32: vrlzFnv,
            expectedSha256: vrlzSha,
            requireVrlzSignature: true,
          ),
          isTrue,
        );

        // Corrupting a payload byte inside validVrlz fails verifyBundle even without external checksums!
        final tamperedVrlz = Uint8List.fromList(validVrlz);
        tamperedVrlz[tamperedVrlz.length - 10] ^= 0xFF;
        expect(VrPackageIntegrityVerifier.verifyBundle(tamperedVrlz), isFalse);

        // Valid encoded .vrlw regional bundle passes full structural verification.
        final validVrlw = VrlwBundleCodec.encode(<String, Object?>{
          'schemaVersion': 1,
          'id': 'org.vrlizate.test.place',
          'title': 'Test Place',
          'revision': '1',
          'license': 'Apache-2.0',
          'gridId': 'default',
          'cellSizeMeters': 12.0,
          'prototypes': const <String>['prop.tree'],
          'origin': const <String, Object?>{'type': 'local'},
          'regions': const <Object?>[
            <String, Object?>{
              'x': 0,
              'z': 0,
              'entities': <Object?>[
                <String, Object?>{
                  'id': 'tree-1',
                  'prototypeId': 'prop.tree',
                  'x': 2.0,
                  'y': 0.0,
                  'z': 3.0,
                },
              ],
            },
          ],
        });
        expect(
          VrPackageIntegrityVerifier.verifyBundle(
            validVrlw,
            requireVrlwSignature: true,
          ),
          isTrue,
        );

        // Corrupting a compressed region byte inside validVrlw fails verifyBundle!
        final tamperedVrlw = Uint8List.fromList(validVrlw);
        tamperedVrlw[tamperedVrlw.length - 1] ^= 0xFF;
        expect(VrPackageIntegrityVerifier.verifyBundle(tamperedVrlw), isFalse);
      },
    );
  });
}
