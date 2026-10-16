import '../bundles/vrlz_package.dart';

/// Budgets for one non-recursive, native directory scan.
class VrlzDiscoveryLimits {
  const VrlzDiscoveryLimits({
    this.maxFiles = 128,
    this.maxFileBytes = VrlzPackage.maxBytes,
    this.maxTotalBytes = 256 * 1024 * 1024,
    this.maxDirectoryEntries = 4096,
  });

  final int maxFiles, maxFileBytes, maxTotalBytes, maxDirectoryEntries;

  void validate() {
    if (maxFiles < 1 ||
        maxFiles > 4096 ||
        maxFileBytes < 1 ||
        maxFileBytes > VrlzPackage.maxBytes ||
        maxTotalBytes < 1 ||
        maxDirectoryEntries < maxFiles ||
        maxDirectoryEntries > 65536) {
      throw ArgumentError('Invalid VRLZ directory discovery limits.');
    }
  }
}

/// Metadata only: listing a directory does not retain every scene's GLB bytes.
class VrlzPackageMetadata {
  const VrlzPackageMetadata({
    required this.id,
    required this.title,
    required this.description,
    required this.kind,
    this.demoId,
  });

  factory VrlzPackageMetadata.fromPackage(VrlzPackage package) =>
      VrlzPackageMetadata(
        id: package.id,
        title: package.title,
        description: package.description,
        kind: package.kind,
        demoId: package.demoId,
      );

  final String id, title, description;
  final VrlzPackageKind kind;
  final String? demoId;
}

/// A selection from a previous scan. [fingerprint] hashes the complete file.
class VrlzDirectoryEntry {
  const VrlzDirectoryEntry({
    required this.rootPath,
    required this.path,
    required this.fileName,
    required this.metadata,
    required this.fingerprint,
    required this.byteLength,
  });

  final String rootPath, path, fileName, fingerprint;
  final int byteLength;
  final VrlzPackageMetadata metadata;
}

enum VrlzDiscoveryIssueKind {
  unavailable,
  inaccessible,
  symbolicLink,
  invalidPackage,
  fileTooLarge,
  directoryLimit,
  totalByteLimit,
  duplicateId,
  changedFile,
  importConflict,
}

class VrlzDirectoryIssue {
  const VrlzDirectoryIssue({
    required this.path,
    required this.fileName,
    required this.kind,
    required this.message,
    this.packageId,
  });

  final String path, fileName, message;
  final String? packageId;
  final VrlzDiscoveryIssueKind kind;
}

class VrlzDirectorySnapshot {
  VrlzDirectorySnapshot({
    required this.rootPath,
    required Iterable<VrlzDirectoryEntry> entries,
    required Iterable<VrlzDirectoryIssue> issues,
    required this.isComplete,
  }) : entries = List.unmodifiable(entries),
       issues = List.unmodifiable(issues);

  final String rootPath;
  final List<VrlzDirectoryEntry> entries;
  final List<VrlzDirectoryIssue> issues;

  /// False means a budget, directory or I/O failure prevented a full scan.
  /// Invalid packages and duplicate IDs still produce a complete, usable scan.
  final bool isComplete;
}

class VrlzDiscoveryException implements Exception {
  const VrlzDiscoveryException(this.kind, this.message, {this.path});
  final VrlzDiscoveryIssueKind kind;
  final String message;
  final String? path;
  @override
  String toString() => message;
}
