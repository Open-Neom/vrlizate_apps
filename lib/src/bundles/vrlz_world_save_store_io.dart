import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'vrlz_world_session.dart';

/// Durable private-app save directory, supplied by the host (documents/support,
/// never a disposable cache). Filenames never interpolate untrusted IDs.
/// Writes flush a sibling temporary file and atomically replace the save.
final class VrlzWorldSaveStore implements VrlzWorldPersistence {
  VrlzWorldSaveStore({required String directoryPath})
    : _directory = Directory(directoryPath).absolute;

  final Directory _directory;
  static final _writes = <String, Future<void>>{};
  static final _random = Random.secure();

  File _file(String experienceId) {
    if (!RegExp(r'^[a-z0-9][a-z0-9._-]{0,95}$').hasMatch(experienceId)) {
      throw const FormatException('Invalid save experience identifier.');
    }
    final digest = crypto.sha256.convert(utf8.encode(experienceId));
    return File('${_directory.path}${Platform.pathSeparator}$digest.vrlsave');
  }

  Future<Uint8List?> _read(File file, String experienceId) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw const FileSystemException('Save path must be a regular file.');
    }
    final handle = await file.open();
    try {
      final data = await handle.read(VrlzWorldSnapshot.maxBytes + 1);
      try {
        final state = VrlzWorldSnapshot.decode(data);
        return state['experienceId'] == experienceId ? data : null;
      } on FormatException {
        return null;
      }
    } finally {
      await handle.close();
    }
  }

  @override
  Future<Uint8List?> read(String experienceId) async {
    final file = _file(experienceId);
    final pending = _writes[file.path];
    if (pending != null) {
      try {
        await pending;
      } catch (_) {
        /* Report readable prior state. */
      }
    }
    return _read(file, experienceId);
  }

  @override
  Future<void> write(String experienceId, Uint8List data) {
    final file = _file(experienceId);
    if (data.length > VrlzWorldSnapshot.maxBytes) {
      throw const FormatException('Save exceeds budget.');
    }
    // Own the bytes before queueing: caller reuse cannot corrupt pending saves.
    final copy = Uint8List.fromList(data);
    final state = VrlzWorldSnapshot.decode(copy);
    if (state['experienceId'] != experienceId) {
      throw const FormatException('Save belongs to a different experience.');
    }
    final previous = _writes[file.path] ?? Future<void>.value();
    final next = previous.catchError((Object _) {}).then((_) async {
      await _directory.create(recursive: true);
      final existing = await _read(file, experienceId);
      if (existing != null) {
        final old = VrlzWorldSnapshot.decode(existing);
        // A debounced older snapshot can arrive after a newer transition save.
        // The timestamp also orders snapshots across package revision changes.
        if ((old['savedAtMicros'] as int) >= (state['savedAtMicros'] as int) ||
            (old['manifestSha256'] == state['manifestSha256'] &&
                (old['sequence'] as int) > (state['sequence'] as int))) {
          return;
        }
      }
      final nonce = List.generate(
        4,
        (_) => _random.nextInt(1 << 30).toRadixString(16),
      ).join();
      final temporary = File('${file.path}.tmp.$pid.$nonce');
      try {
        await temporary.writeAsBytes(copy, flush: true);
        await temporary.rename(file.path);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    });
    _writes[file.path] = next;
    // Both success and failure remove only this generation's queue entry.
    unawaited(
      next.then<void>(
        (_) {
          if (identical(_writes[file.path], next)) _writes.remove(file.path);
        },
        onError: (Object _, StackTrace __) {
          if (identical(_writes[file.path], next)) _writes.remove(file.path);
        },
      ),
    );
    return next;
  }
}
