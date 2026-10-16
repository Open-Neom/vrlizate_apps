import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../bundles/vrlz_package.dart';
import '../bundles/vrlz_world_bundle.dart';
import 'vrlz_discovery_models.dart';

/// Reads only regular .vrlz files directly inside the selected directory.
///
/// Scanning never creates files or starts a watcher. The host decides when to
/// refresh and when an explicit import is allowed. This store assumes the host
/// controls its directory; dart:io cannot make path checks immune to a hostile
/// process replacing directories between filesystem operations.
class VrlzDirectoryStore {
  VrlzDirectoryStore(
    this.directoryPath, {
    this.limits = const VrlzDiscoveryLimits(),
  }) {
    limits.validate();
    if (directoryPath.trim().isEmpty) {
      throw ArgumentError.value(directoryPath, 'directoryPath');
    }
  }

  static const supported = true;
  final String directoryPath;
  final VrlzDiscoveryLimits limits;

  // Coalesce work within this isolate; an exclusive coordination file below
  // provides exclusion across other isolates and processes as well.
  static final _imports = <String, Future<void>>{};

  Future<VrlzDirectorySnapshot> scan() async {
    String root = Directory(directoryPath).absolute.path;
    try {
      root = await _root();
      final pending = _imports[root];
      if (pending != null) await pending;
      return await _scan(root);
    } on VrlzDiscoveryException catch (error) {
      return _failed(root, error);
    } on FileSystemException catch (error) {
      return _failed(root, _ioError(error, root));
    }
  }

  /// Revalidates bytes and identity immediately before launching a selection.
  /// A changed file must be selected again from a refreshed catalog.
  Future<VrlzPackage> load(VrlzDirectoryEntry entry) async {
    final root = await _root();
    final pending = _imports[root];
    if (pending != null) await pending;
    _validateFilename(entry.fileName, forImport: false);
    final file = _child(root, entry.fileName);
    if (entry.rootPath != root || entry.path != file.path) {
      throw VrlzDiscoveryException(
        VrlzDiscoveryIssueKind.changedFile,
        'The selected package does not belong to this directory.',
        path: entry.path,
      );
    }
    final bytes = await _read(
      root,
      file,
      budget: _ReadBudget(limits.maxTotalBytes),
    );
    if (bytes.length != entry.byteLength ||
        sha256.convert(bytes).toString() != entry.fingerprint) {
      throw VrlzDiscoveryException(
        VrlzDiscoveryIssueKind.changedFile,
        'The package changed. Refresh the directory and select it again.',
        path: file.path,
      );
    }
    final package = _decodeFile(
      bytes,
      fileName: entry.fileName,
      source: file.uri,
    );
    if (package.id != entry.metadata.id) {
      throw VrlzDiscoveryException(
        VrlzDiscoveryIssueKind.changedFile,
        'The package identity changed. Refresh the directory.',
        path: file.path,
      );
    }
    return package;
  }

  /// Explicit import only. Creates the directory after validating the bytes.
  ///
  /// The destination is first reserved with exclusive creation. Bytes are
  /// flushed to a private temporary file and atomically replace that reservation;
  /// pre-existing destinations are never renamed over. Store scans wait for the
  /// import to finish. Other filesystem readers may briefly see the empty
  /// reservation, but never a partially written package.
  Future<VrlzDirectoryEntry> importBytes(
    Uint8List bytes, {
    String? filename,
  }) async {
    if (bytes.length > limits.maxFileBytes ||
        bytes.length > limits.maxTotalBytes) {
      throw const VrlzDiscoveryException(
        VrlzDiscoveryIssueKind.fileTooLarge,
        'The imported package exceeds the directory byte budget.',
      );
    }
    if (filename != null) {
      _validateFilename(filename);
    }
    // Callers cannot mutate the validation input while asynchronous I/O runs.
    final ownedBytes = Uint8List.fromList(bytes);
    final isRawNes =
        (filename != null && filename.toLowerCase().endsWith('.nes')) ||
        (filename == null && _hasInesMagic(ownedBytes));
    final isRawVrlw =
        filename == null && VrlzWorldBundle.hasRawVrlwMagic(ownedBytes);
    final package = isRawNes
        ? VrlzPackage.fromRawNesRom(
            ownedBytes,
            fileName: filename ?? 'cartridge.nes',
          )
        : VrlzPackage.decode(ownedBytes);
    final name =
        filename ??
        (isRawNes
            ? '${package.id}.nes'
            : isRawVrlw
            ? '${package.id}.vrlw'
            : '${package.id}.vrlz');
    _validateFilename(name);
    final root = await _root(create: true);
    final previous = _imports[root];
    final done = Completer<void>();
    _imports[root] = done.future;
    try {
      if (previous != null) await previous;
      return await _import(root, name, ownedBytes, package);
    } finally {
      done.complete();
      if (identical(_imports[root], done.future)) _imports.remove(root);
    }
  }

  Future<VrlzDirectoryEntry> _import(
    String root,
    String name,
    Uint8List bytes,
    VrlzPackage package,
  ) async {
    await _checkRoot(root);
    final lockFile = _child(root, '.vrlizate-import.lock');
    final random = math.Random.secure();
    final token = jsonEncode({
      'owner': List.generate(
        24,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join(),
      'pid': pid,
      'createdUtc': DateTime.now().toUtc().toIso8601String(),
    });
    // File.create(exclusive:true) is the acquisition operation. Advisory file
    // locks are process-scoped on POSIX and cannot exclude another Dart isolate.
    // Never open/truncate an existing coordination file, including a symlink.
    try {
      await lockFile.create(exclusive: true);
    } on FileSystemException {
      throw VrlzDiscoveryException(
        VrlzDiscoveryIssueKind.importConflict,
        'Another import owns this directory, or its coordination file remains. '
        'Retry after it finishes. Remove a residual .vrlizate-import.lock only '
        'after confirming no process is importing.',
        path: lockFile.path,
      );
    }
    FileStat? ownership;
    try {
      await _regularFile(root, lockFile);
      await lockFile.writeAsString(token, flush: true);
      ownership = await lockFile.stat();
      final snapshot = await _scan(root);
      if (!snapshot.isComplete) {
        throw const VrlzDiscoveryException(
          VrlzDiscoveryIssueKind.importConflict,
          'The directory could not be fully checked before importing.',
        );
      }
      if (snapshot.entries.any((entry) => entry.metadata.id == package.id) ||
          snapshot.issues.any((issue) => issue.packageId == package.id)) {
        throw VrlzDiscoveryException(
          VrlzDiscoveryIssueKind.duplicateId,
          'A package with ID ${package.id} already exists in this directory.',
        );
      }
      // Recheck budgets including invalid files, not only visible catalog cards.
      final candidates = await _candidates(root);
      var total = bytes.length;
      if (candidates.length >= limits.maxFiles) {
        throw const VrlzDiscoveryException(
          VrlzDiscoveryIssueKind.directoryLimit,
          'The directory package limit has been reached.',
        );
      }
      for (final file in candidates) {
        if (await FileSystemEntity.type(file.path, followLinks: false) ==
            FileSystemEntityType.file) {
          total += (await file.stat()).size;
        }
      }
      if (total > limits.maxTotalBytes) {
        throw const VrlzDiscoveryException(
          VrlzDiscoveryIssueKind.totalByteLimit,
          'Importing this package would exceed the directory byte budget.',
        );
      }
      return await _publish(root, name, bytes, package);
    } finally {
      // A crash or failed write can leave a residual marker. It is intentionally
      // never reclaimed by age: a slow importer may still own it. Only remove
      // the marker whose exact token and metadata we wrote ourselves.
      if (ownership != null) {
        await _releaseCoordination(root, lockFile, token, ownership);
      }
    }
  }

  Future<void> _releaseCoordination(
    String root,
    File file,
    String token,
    FileStat ownership,
  ) async {
    try {
      await _checkRoot(root);
      await _regularFile(root, file);
      final stat = await file.stat();
      final expected = utf8.encode(token);
      if (stat.size != expected.length ||
          stat.modified != ownership.modified ||
          stat.changed != ownership.changed) {
        return;
      }
      final content = BytesBuilder(copy: false);
      // Bounded even if another process replaces or enlarges this marker.
      await for (final chunk in file.openRead(0, expected.length + 1)) {
        content.add(chunk);
      }
      if (content.length != expected.length ||
          utf8.decode(content.takeBytes(), allowMalformed: true) != token) {
        return;
      }
      await _regularFile(root, file);
      final current = await file.stat();
      if (current.size == stat.size &&
          current.modified == stat.modified &&
          current.changed == stat.changed) {
        await file.delete();
      }
    } on FileSystemException {
      // Preserve a foreign/replaced marker and do not hide the import outcome.
    } on VrlzDiscoveryException {
      // Directory ownership changed; do not delete through the changed path.
    }
  }

  Future<VrlzDirectoryEntry> _publish(
    String root,
    String name,
    Uint8List bytes,
    VrlzPackage package,
  ) async {
    await _checkRoot(root);
    final destination = _child(root, name);
    try {
      await destination.create(exclusive: true);
    } on FileSystemException {
      throw VrlzDiscoveryException(
        VrlzDiscoveryIssueKind.importConflict,
        'A file named $name already exists or cannot be created.',
        path: destination.path,
      );
    }
    final reservation = await destination.stat();
    Directory? temporary;
    var published = false;
    try {
      temporary = await Directory(root).createTemp('.vrlizate-import-');
      final staged = File.fromUri(temporary.uri.resolve('package.part'));
      await staged.writeAsBytes(bytes, flush: true);
      await _checkRoot(root);
      if (!await _isReservation(root, destination, reservation)) {
        throw VrlzDiscoveryException(
          VrlzDiscoveryIssueKind.importConflict,
          'The reserved destination changed before the import completed.',
          path: destination.path,
        );
      }
      await staged.rename(destination.path);
      published = true;
      return _entry(root, destination, bytes, package);
    } finally {
      if (!published && await _isReservation(root, destination, reservation)) {
        await destination.delete();
      }
      if (temporary != null &&
          await FileSystemEntity.type(temporary.path, followLinks: false) ==
              FileSystemEntityType.directory &&
          await temporary.resolveSymbolicLinks() == temporary.path) {
        await temporary.delete(recursive: true);
      }
    }
  }

  Future<bool> _isReservation(String root, File file, FileStat original) async {
    try {
      await _checkRoot(root);
      await _regularFile(root, file);
      final current = await file.stat();
      return current.size == 0 &&
          current.modified == original.modified &&
          current.changed == original.changed;
    } on FileSystemException {
      return false;
    } on VrlzDiscoveryException {
      return false;
    }
  }

  Future<VrlzDirectorySnapshot> _scan(String root) async {
    final candidates = await _candidates(root);
    final issues = <VrlzDirectoryIssue>[];
    final readable = <File>[];
    var total = 0;
    var complete = true;
    for (final file in candidates) {
      try {
        await _regularFile(root, file);
        final size = (await file.stat()).size;
        if (size > limits.maxFileBytes) {
          throw VrlzDiscoveryException(
            VrlzDiscoveryIssueKind.fileTooLarge,
            'Package exceeds the per-file byte budget.',
            path: file.path,
          );
        }
        total += size;
        if (total > limits.maxTotalBytes) {
          throw const VrlzDiscoveryException(
            VrlzDiscoveryIssueKind.totalByteLimit,
            'Directory packages exceed the total scan byte budget.',
          );
        }
        readable.add(file);
      } on VrlzDiscoveryException catch (error) {
        if (error.kind == VrlzDiscoveryIssueKind.totalByteLimit) rethrow;
        issues.add(_issue(file, error));
      } on FileSystemException catch (error) {
        complete = false;
        issues.add(_issue(file, _ioError(error, file.path)));
      }
    }
    final byId = <String, List<VrlzDirectoryEntry>>{};
    final budget = _ReadBudget(limits.maxTotalBytes);
    for (final file in readable) {
      try {
        final bytes = await _read(root, file, budget: budget);
        final package = _decodeFile(
          bytes,
          fileName: _name(file.path),
          source: file.uri,
        );
        final entry = _entry(root, file, bytes, package);
        byId.putIfAbsent(package.id, () => []).add(entry);
      } on FormatException catch (error) {
        issues.add(
          _issue(
            file,
            VrlzDiscoveryException(
              VrlzDiscoveryIssueKind.invalidPackage,
              'Invalid VRLZ package: ${error.message}',
              path: file.path,
            ),
          ),
        );
      } on VrlzDiscoveryException catch (error) {
        if (error.kind == VrlzDiscoveryIssueKind.totalByteLimit) rethrow;
        if (error.kind == VrlzDiscoveryIssueKind.changedFile) complete = false;
        issues.add(_issue(file, error));
      } on FileSystemException catch (error) {
        complete = false;
        issues.add(_issue(file, _ioError(error, file.path)));
      } catch (error) {
        // A malformed package must not suppress unrelated, valid entries even
        // if an underlying decoder reports a non-FormatException failure.
        issues.add(
          _issue(
            file,
            VrlzDiscoveryException(
              VrlzDiscoveryIssueKind.invalidPackage,
              'The package could not be decoded: $error',
              path: file.path,
            ),
          ),
        );
      }
    }
    final entries = <VrlzDirectoryEntry>[];
    for (final group in byId.values) {
      if (group.length == 1) {
        entries.add(group.single);
      } else {
        for (final entry in group) {
          issues.add(
            VrlzDirectoryIssue(
              path: entry.path,
              fileName: entry.fileName,
              kind: VrlzDiscoveryIssueKind.duplicateId,
              packageId: entry.metadata.id,
              message:
                  'Duplicate ID ${entry.metadata.id}; none of its ${group.length} files will be selected.',
            ),
          );
        }
      }
    }
    entries.sort((a, b) => a.fileName.compareTo(b.fileName));
    issues.sort((a, b) => a.fileName.compareTo(b.fileName));
    await _checkRoot(root);
    return VrlzDirectorySnapshot(
      rootPath: root,
      entries: entries,
      issues: issues,
      isComplete: complete,
    );
  }

  Future<List<File>> _candidates(String root) async {
    await _checkRoot(root);
    var visited = 0;
    final files = <File>[];
    await for (final entity in Directory(root).list(followLinks: false)) {
      visited++;
      if (visited > limits.maxDirectoryEntries) {
        throw const VrlzDiscoveryException(
          VrlzDiscoveryIssueKind.directoryLimit,
          'Directory entry limit exceeded. No partial catalog was selected.',
        );
      }
      if (_isSupportedFilename(_name(entity.path))) {
        files.add(File(entity.path));
        if (files.length > limits.maxFiles) {
          throw const VrlzDiscoveryException(
            VrlzDiscoveryIssueKind.directoryLimit,
            'Package count limit exceeded. No partial catalog was selected.',
          );
        }
      }
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  Future<Uint8List> _read(String root, File file, {_ReadBudget? budget}) async {
    await _checkRoot(root);
    await _regularFile(root, file);
    final before = await file.stat();
    if (before.size > limits.maxFileBytes) {
      throw VrlzDiscoveryException(
        VrlzDiscoveryIssueKind.fileTooLarge,
        'Package exceeds the per-file byte budget.',
        path: file.path,
      );
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in file.openRead()) {
      if (builder.length + chunk.length > limits.maxFileBytes) {
        throw VrlzDiscoveryException(
          VrlzDiscoveryIssueKind.fileTooLarge,
          'Package grew beyond the per-file byte budget.',
          path: file.path,
        );
      }
      if (budget != null && chunk.length > budget.remaining) {
        throw const VrlzDiscoveryException(
          VrlzDiscoveryIssueKind.totalByteLimit,
          'Files changed beyond the total scan byte budget.',
        );
      }
      if (budget != null) budget.remaining -= chunk.length;
      builder.add(chunk);
    }
    await _regularFile(root, file);
    final after = await file.stat();
    await _checkRoot(root);
    if (before.size != after.size ||
        before.modified != after.modified ||
        before.changed != after.changed ||
        builder.length != after.size) {
      throw VrlzDiscoveryException(
        VrlzDiscoveryIssueKind.changedFile,
        'Package changed while it was being read. Refresh the directory.',
        path: file.path,
      );
    }
    return builder.takeBytes();
  }

  Future<String> _root({bool create = false}) async {
    final directory = Directory(directoryPath).absolute;
    var type = await FileSystemEntity.type(directory.path, followLinks: false);
    if (type == FileSystemEntityType.notFound && create) {
      await directory.create(recursive: true);
      type = await FileSystemEntity.type(directory.path, followLinks: false);
    }
    if (type == FileSystemEntityType.link) {
      throw VrlzDiscoveryException(
        VrlzDiscoveryIssueKind.symbolicLink,
        'A symbolic link cannot be used as a package directory.',
        path: directory.path,
      );
    }
    if (type != FileSystemEntityType.directory) {
      throw VrlzDiscoveryException(
        VrlzDiscoveryIssueKind.unavailable,
        'The package directory does not exist or is unavailable.',
        path: directory.path,
      );
    }
    return directory.resolveSymbolicLinks();
  }

  Future<void> _checkRoot(String root) async {
    if (await _root() != root) {
      throw VrlzDiscoveryException(
        VrlzDiscoveryIssueKind.changedFile,
        'The package directory changed during the operation.',
        path: root,
      );
    }
  }

  Future<void> _regularFile(String root, File file) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw VrlzDiscoveryException(
        VrlzDiscoveryIssueKind.symbolicLink,
        'Symbolic links are not loaded as packages.',
        path: file.path,
      );
    }
    if (type != FileSystemEntityType.file ||
        file.parent.absolute.path != root ||
        await file.resolveSymbolicLinks() != file.path) {
      throw VrlzDiscoveryException(
        VrlzDiscoveryIssueKind.changedFile,
        'The package is no longer a regular file directly inside this directory.',
        path: file.path,
      );
    }
  }

  static File _child(String root, String name) =>
      File.fromUri(Directory(root).uri.resolve(Uri(path: name).toString()));
  static String _name(String path) => File(path).uri.pathSegments.last;

  static bool _isSupportedFilename(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.vrlz') ||
        lower.endsWith('.vrlw') ||
        lower.endsWith('.nes');
  }

  static bool _hasInesMagic(Uint8List bytes) =>
      bytes.length >= 16 &&
      bytes[0] == 0x4E &&
      bytes[1] == 0x45 &&
      bytes[2] == 0x53 &&
      bytes[3] == 0x1A;

  static VrlzPackage _decodeFile(
    Uint8List bytes, {
    required String fileName,
    Uri? source,
  }) => fileName.toLowerCase().endsWith('.nes')
      ? VrlzPackage.fromRawNesRom(bytes, fileName: fileName, source: source)
      : VrlzPackage.decode(bytes, source: source);

  static void _validateFilename(String name, {bool forImport = true}) {
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains('\\') ||
        (forImport && name.contains(':')) ||
        name.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
        !_isSupportedFilename(name) ||
        (forImport && utf8.encode(name).length > 180)) {
      throw const VrlzDiscoveryException(
        VrlzDiscoveryIssueKind.importConflict,
        'Use a plain filename ending in .vrlz, .vrlw or .nes, without a directory component.',
      );
    }
  }

  static VrlzDirectoryEntry _entry(
    String root,
    File file,
    Uint8List bytes,
    VrlzPackage package,
  ) => VrlzDirectoryEntry(
    rootPath: root,
    path: file.path,
    fileName: _name(file.path),
    metadata: VrlzPackageMetadata.fromPackage(package),
    fingerprint: sha256.convert(bytes).toString(),
    byteLength: bytes.length,
  );

  static VrlzDirectoryIssue _issue(File file, VrlzDiscoveryException error) =>
      VrlzDirectoryIssue(
        path: file.path,
        fileName: _name(file.path),
        kind: error.kind,
        message: error.message,
      );

  static VrlzDiscoveryException _ioError(
    FileSystemException error,
    String path,
  ) => VrlzDiscoveryException(
    VrlzDiscoveryIssueKind.inaccessible,
    'Cannot read the package directory or file: ${error.message}',
    path: path,
  );

  static VrlzDirectorySnapshot _failed(
    String root,
    VrlzDiscoveryException error,
  ) => VrlzDirectorySnapshot(
    rootPath: root,
    entries: const [],
    isComplete: false,
    issues: [
      VrlzDirectoryIssue(
        path: error.path ?? root,
        fileName: '',
        kind: error.kind,
        message: error.message,
      ),
    ],
  );
}

class _ReadBudget {
  _ReadBudget(this.remaining);
  int remaining;
}
