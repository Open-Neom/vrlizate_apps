import 'dart:async';
import 'dart:typed_data';

import 'package:vrlizate_apps/vrlizate_apps.dart';

VrlzExpeditionDefinition expeditionFixture({
  int revision = 1,
  String title = 'Expedición',
}) => VrlzExpeditionDefinition(
  id: 'openneom.expedition',
  experienceId: 'openneom.worlds',
  title: title,
  revision: revision,
  worlds: {'garden': 'Jardín', 'gallery': 'Galería'},
  missions: [
    VrlzExpeditionMission(
      id: 'first',
      world: 'garden',
      title: 'Mirar',
      instruction: 'Acércate a la forma.',
      discovery: 'Una forma original.',
      position: [1, 1.6, 2],
    ),
    VrlzExpeditionMission(
      id: 'second',
      world: 'gallery',
      title: 'Explorar',
      instruction: 'Entra en la galería.',
      discovery: 'Un tragaluz abierto.',
      position: [4, 1.6, 4],
      radius: 1,
    ),
    VrlzExpeditionMission(
      id: 'third',
      world: 'gallery',
      title: 'Descubrir',
      instruction: 'Observa el patio.',
      discovery: 'Una exposición espacial.',
      position: [7, 1.6, 5],
      radius: 2,
    ),
  ],
);

final class ExpeditionMemoryStore implements VrlzExpeditionPersistence {
  Uint8List? bytes;
  int reads = 0,
      writes = 0,
      activeWrites = 0,
      maxActiveWrites = 0,
      failWrites = 0,
      failReads = 0;
  Completer<void>? readGate, nextWriteGate;
  final payloads = <Uint8List>[];

  @override
  Future<Uint8List?> read(String expeditionId) async {
    reads++;
    if (readGate case final gate?) await gate.future;
    if (failReads > 0) {
      failReads--;
      throw StateError('private read path/token');
    }
    return bytes == null ? null : Uint8List.fromList(bytes!);
  }

  @override
  Future<void> write(String expeditionId, Uint8List data) async {
    writes++;
    activeWrites++;
    if (activeWrites > maxActiveWrites) maxActiveWrites = activeWrites;
    final payload = Uint8List.fromList(data);
    payloads.add(payload);
    final gate = nextWriteGate;
    nextWriteGate = null;
    try {
      if (gate != null) await gate.future;
      if (failWrites > 0) {
        failWrites--;
        throw StateError('private write path/token');
      }
      bytes = payload;
    } finally {
      activeWrites--;
    }
  }
}
