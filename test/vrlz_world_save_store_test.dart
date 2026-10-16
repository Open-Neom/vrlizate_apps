import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_apps/vrlizate_apps.dart';
import 'package:vrlizate_apps/vrlizate_apps_io.dart';

import 'support/vrlz_world_fixture.dart';

void main() {
  late Directory directory;
  late VrlzWorldBundle bundle;
  late VrlzWorldSaveStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('vrlz-world-save-');
    bundle = VrlzWorldBundle.decode(fixtureWorlds());
    store = VrlzWorldSaveStore(directoryPath: directory.path);
  });
  tearDown(() async => directory.delete(recursive: true));

  test('new store and session restore durable world state', () async {
    final session = VrlzWorldSession(bundle)..enterPortal('to_gallery');
    session.updatePose(const VrlzWorldPose(x: 5, y: 1.6, z: 4, yaw: .8));
    await store.write(bundle.manifest.id, session.encodeSnapshot());
    final afterRestart = VrlzWorldSaveStore(directoryPath: directory.path);
    final freshSession = VrlzWorldSession(bundle);
    expect(
      freshSession.restoreSnapshot(
        (await afterRestart.read(bundle.manifest.id))!,
      ),
      isTrue,
    );
    expect(freshSession.currentWorld, 'gallery');
    expect(freshSession.pose.position, [5, 1.6, 4]);
    final files = await directory.list().toList();
    expect(files.length, 1);
    expect(
      files.single.path.split(Platform.pathSeparator).last,
      matches(r'^[0-9a-f]{64}\.vrlsave$'),
    );
  });

  test(
    'late stale save cannot overwrite a newer transition across store instances',
    () async {
      final session = VrlzWorldSession(bundle);
      final old = session.encodeSnapshot();
      session.enterPortal('to_gallery');
      final newer = session.encodeSnapshot();
      final secondStore = VrlzWorldSaveStore(directoryPath: directory.path);
      await Future.wait([
        store.write(bundle.manifest.id, newer),
        secondStore.write(bundle.manifest.id, old),
      ]);
      final restored = VrlzWorldSession(bundle);
      expect(
        restored.restoreSnapshot((await store.read(bundle.manifest.id))!),
        isTrue,
      );
      expect(restored.currentWorld, 'gallery');
    },
  );

  test(
    'pending writes copy input bytes and read waits for atomic replacement',
    () async {
      final session = VrlzWorldSession(bundle)..enterPortal('to_gallery');
      final bytes = session.encodeSnapshot();
      final pending = store.write(bundle.manifest.id, bytes);
      bytes.fillRange(0, bytes.length, 0);
      final read = await store.read(bundle.manifest.id);
      await pending;
      final restored = VrlzWorldSession(bundle);
      expect(restored.restoreSnapshot(read!), isTrue);
      expect(restored.currentWorld, 'gallery');
      expect((await directory.list().toList()).length, 1);
    },
  );

  test(
    'corrupt disk save is ignored and replaced without deleting other files',
    () async {
      final session = VrlzWorldSession(bundle);
      await store.write(bundle.manifest.id, session.encodeSnapshot());
      final file = (await directory.list().toList()).single as File;
      await file.writeAsBytes([1, 2, 3]);
      expect(await store.read(bundle.manifest.id), isNull);
      final unrelated = File('${directory.path}/notes.txt');
      await unrelated.writeAsString('keep');
      session.enterPortal('to_gallery');
      await store.write(bundle.manifest.id, session.encodeSnapshot());
      expect(await store.read(bundle.manifest.id), isNotNull);
      expect(await unrelated.readAsString(), 'keep');
    },
  );

  test('wrong identity, oversize and unsafe paths cannot write', () async {
    final bytes = VrlzWorldSession(bundle).encodeSnapshot();
    expect(() => store.write('../outside', bytes), throwsFormatException);
    expect(() => store.write('test.other', bytes), throwsFormatException);
    expect(
      () => store.write(bundle.manifest.id, Uint8List(20000)),
      throwsFormatException,
    );
    expect(await directory.list().toList(), isEmpty);
  });

  test('failed write does not poison the next valid queued write', () async {
    final session = VrlzWorldSession(bundle);
    // A regular file where the directory should be makes create fail.
    final blocker = File('${directory.path}/blocked');
    await blocker.writeAsString('block');
    final blockedStore = VrlzWorldSaveStore(directoryPath: blocker.path);
    await expectLater(
      blockedStore.write(bundle.manifest.id, session.encodeSnapshot()),
      throwsA(isA<FileSystemException>()),
    );
    await blocker.delete();
    session.enterPortal('to_gallery');
    await blockedStore.write(bundle.manifest.id, session.encodeSnapshot());
    final fresh = VrlzWorldSession(bundle);
    expect(
      fresh.restoreSnapshot((await blockedStore.read(bundle.manifest.id))!),
      isTrue,
    );
    expect(fresh.currentWorld, 'gallery');
  });
}
