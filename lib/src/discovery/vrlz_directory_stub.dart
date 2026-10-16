import 'dart:typed_data';

import '../bundles/vrlz_package.dart';
import 'vrlz_discovery_models.dart';

/// Directory discovery is available only on platforms with dart:io.
class VrlzDirectoryStore {
  VrlzDirectoryStore(
    this.directoryPath, {
    this.limits = const VrlzDiscoveryLimits(),
  }) {
    limits.validate();
  }
  final String directoryPath;
  final VrlzDiscoveryLimits limits;
  static const supported = false;

  Future<VrlzDirectorySnapshot> scan() async => VrlzDirectorySnapshot(
    rootPath: directoryPath,
    entries: const [],
    issues: [
      VrlzDirectoryIssue(
        path: directoryPath,
        fileName: '',
        kind: VrlzDiscoveryIssueKind.unavailable,
        message: 'Directory discovery requires a native application.',
      ),
    ],
    isComplete: false,
  );

  Future<VrlzPackage> load(VrlzDirectoryEntry entry) async =>
      throw const VrlzDiscoveryException(
        VrlzDiscoveryIssueKind.unavailable,
        'Native directory access is unavailable.',
      );

  Future<VrlzDirectoryEntry> importBytes(
    Uint8List bytes, {
    String? filename,
  }) async => throw const VrlzDiscoveryException(
    VrlzDiscoveryIssueKind.unavailable,
    'Native directory access is unavailable.',
  );
}
