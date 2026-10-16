import 'dart:typed_data';

import 'vrlz_world_session.dart';

/// Web hosts supply an IndexedDB/etc. implementation of the core interface.
final class VrlzWorldSaveStore implements VrlzWorldPersistence {
  VrlzWorldSaveStore({required String directoryPath});
  @override
  Future<Uint8List?> read(String experienceId) async =>
      throw UnsupportedError('Native world saves require dart:io.');
  @override
  Future<void> write(String experienceId, Uint8List data) async =>
      throw UnsupportedError('Native world saves require dart:io.');
}
