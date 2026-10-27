import 'dart:typed_data';

/// Host-owned local persistence. The core never imports a filesystem or cloud.
abstract interface class VrlzExpeditionPersistence {
  Future<Uint8List?> read(String expeditionId);
  Future<void> write(String expeditionId, Uint8List data);
}
