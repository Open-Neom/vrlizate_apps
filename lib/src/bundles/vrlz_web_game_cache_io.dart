import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'vrlz_web_game_cache.dart';

/// Persistent content-addressed LRU. Paths derive only from validated SHA-256;
/// no game-relative path is extracted to disk. Every read rechecks hash/length.
/// As with DirectoryStore, the host must control this app-private directory:
/// dart:io cannot prevent a hostile process racing filesystem path checks.
final class VrlzWebGameFileCache implements VrlzWebGameCache {
  VrlzWebGameFileCache(
    this.directoryPath, {
    this.maxBytes = 64 * 1024 * 1024,
    this.maxFiles = 8192,
  }) {
    if (directoryPath.trim().isEmpty ||
        maxBytes < 1 ||
        maxBytes > 1024 * 1024 * 1024 ||
        maxFiles < 1 ||
        maxFiles > 16384) {
      throw ArgumentError('Invalid persistent web cache limits.');
    }
  }
  static const supported = true;
  final String directoryPath;
  @override
  final int maxBytes;
  final int maxFiles;
  int _byteLength = 0, _fileCount = 0;
  int get byteLength => _byteLength;
  int get fileCount => _fileCount;
  Future<void> _queue = Future.value();

  Future<T> _locked<T>(Future<T> Function() work) {
    final previous = _queue, done = Completer<void>();
    _queue = done.future;
    return () async {
      await previous;
      try {
        return await work();
      } finally {
        done.complete();
      }
    }();
  }

  Future<Directory> _root() async {
    final root = Directory(directoryPath).absolute;
    var type = await FileSystemEntity.type(root.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      await root.create(recursive: true);
      type = await FileSystemEntity.type(root.path, followLinks: false);
    }
    if (type != FileSystemEntityType.directory) {
      throw FileSystemException(
        'Web cache root must be a regular directory.',
        root.path,
      );
    }
    return Directory(await root.resolveSymbolicLinks());
  }

  File _file(Directory root, String hash) {
    validateWebGameHash(hash);
    return File.fromUri(root.uri.resolve('$hash.chunk'));
  }

  Future<FileSystemEntityType> _type(File file) =>
      FileSystemEntity.type(file.path, followLinks: false);

  @override
  Future<Uint8List?> read(String hash, {required int byteLength}) =>
      _locked(() async {
        validateWebGameHash(hash);
        final root = await _root();
        final file = _file(root, hash);
        final type = await _type(file);
        if (type == FileSystemEntityType.notFound) return null;
        if (type != FileSystemEntityType.file) {
          throw const FileSystemException(
            'Web cache entry must not be a symbolic link.',
          );
        }
        final stat = await file.stat();
        if (stat.size != byteLength || stat.size > maxBytes) {
          await file.delete();
          await _prune(root);
          return null;
        }
        final bytes = await file.readAsBytes();
        if (!verifyWebGameBytes(hash, byteLength, bytes)) {
          await file.delete();
          await _prune(root);
          return null;
        }
        await file.setLastModified(DateTime.now());
        await _prune(root);
        return bytes;
      });
  @override
  Future<void> write(String hash, Uint8List bytes) {
    validateWebGameHash(hash);
    final owned = Uint8List.fromList(bytes);
    return _locked(() async {
      if (!verifyWebGameBytes(hash, owned.length, owned)) {
        throw const FormatException('Invalid persistent web cache bytes.');
      }
      final root = await _root();
      if (owned.length > maxBytes) {
        await _prune(root);
        return;
      }
      final file = _file(root, hash), type = await _type(_file(root, hash));
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.file) {
        throw const FileSystemException(
          'Refusing to replace a cache link/directory.',
        );
      }
      final temp = await root.createTemp('.vrlz-web-');
      try {
        final staged = File.fromUri(temp.uri.resolve('resource.part'));
        await staged.writeAsBytes(owned, flush: true);
        final current = await _type(file);
        if (current != FileSystemEntityType.notFound &&
            current != FileSystemEntityType.file) {
          throw const FileSystemException('Cache entry changed type.');
        }
        await staged.rename(file.path);
      } finally {
        await temp.delete(recursive: true);
      }
      await _prune(root);
    });
  }

  @override
  Future<void> remove(String hash) => _locked(() async {
    final root = await _root();
    final file = _file(root, hash);
    final type = await _type(file);
    if (type == FileSystemEntityType.file) {
      await file.delete();
    } else if (type != FileSystemEntityType.notFound) {
      throw const FileSystemException(
        'Refusing to remove a cache link/directory.',
      );
    }
    await _prune(root);
  });
  @override
  Future<void> clear() => _locked(() async {
    final root = await _root();
    for (final entry in await _entries(root)) {
      await entry.$1.delete();
    }
    _byteLength = 0;
    _fileCount = 0;
  });
  Future<void> prune() => _locked(() async {
    await _prune(await _root());
  });

  Future<List<(File, FileStat)>> _entries(Directory root) async {
    final result = <(File, FileStat)>[];
    var scanned = 0;
    await for (final entity in root.list(followLinks: false)) {
      if (++scanned > 65536) {
        throw const FileSystemException(
          'Web cache directory entry budget exceeded.',
        );
      }
      final name = entity.uri.pathSegments.last;
      if (!RegExp(r'^[0-9a-f]{64}\.chunk$').hasMatch(name)) continue;
      if (await FileSystemEntity.type(entity.path, followLinks: false) !=
          FileSystemEntityType.file) {
        continue;
      }
      final file = File(entity.path);
      result.add((file, await file.stat()));
    }
    return result;
  }

  Future<void> _prune(Directory root) async {
    final entries = await _entries(root);
    entries.sort((a, b) {
      final age = a.$2.modified.compareTo(b.$2.modified);
      return age != 0 ? age : a.$1.path.compareTo(b.$1.path);
    });
    var bytes = entries.fold<int>(0, (sum, entry) => sum + entry.$2.size),
        count = entries.length;
    for (final entry in entries) {
      if (bytes <= maxBytes && count <= maxFiles) break;
      if (await _type(entry.$1) == FileSystemEntityType.file) {
        await entry.$1.delete();
        bytes -= entry.$2.size;
        count--;
      }
    }
    _byteLength = bytes;
    _fileCount = count;
  }
}
