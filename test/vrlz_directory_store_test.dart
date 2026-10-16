import 'dart:io';
import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_apps/vrlizate_apps.dart';
import 'package:vrlizate_apps/vrlizate_apps_io.dart';

import 'support/vrz_fixture.dart';

Uint8List descriptor(String id, {String title = 'Alpha'}) =>
    VrlzPackage.encodeBuiltin(id: id, title: title, demoId: 'hello_vr');

Matcher discoveryFailure(VrlzDiscoveryIssueKind kind) =>
    isA<VrlzDiscoveryException>().having((error) => error.kind, 'kind', kind);

Future<void> _isolatedImport((SendPort, String, String) arguments) async {
  final (events, path, name) = arguments;
  final start = ReceivePort();
  events.send(start.sendPort);
  await start.first;
  start.close();
  try {
    await VrlzDirectoryStore(
      path,
    ).importBytes(descriptor('org.example.isolate'), filename: name);
    events.send('ok');
  } on VrlzDiscoveryException catch (error) {
    events.send(error.kind.name);
  } catch (error) {
    events.send('unexpected:$error');
  }
}

void main() {
  late Directory temporary;
  late Directory root;
  late VrlzDirectoryStore store;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('vrlz-discovery-test-');
    root = await Directory.fromUri(temporary.uri.resolve('packages/')).create();
    store = VrlzDirectoryStore(root.path);
  });
  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  Future<File> write(String name, List<int> bytes) => File.fromUri(
    root.uri.resolve(Uri(path: name).toString()),
  ).writeAsBytes(bytes);

  test(
    'native discovery lists scenes and builtin descriptors in stable filename order',
    () async {
      await write('zeta.vrlz', fixtureBundle());
      await write('alpha.VRLZ', descriptor('org.example.alpha'));
      await write('old.vrz', fixtureBundle());
      final nested = await Directory.fromUri(
        root.uri.resolve('nested/'),
      ).create();
      await File.fromUri(
        nested.uri.resolve('ignored.vrlz'),
      ).writeAsBytes(descriptor('org.example.nested'));
      final snapshot = await store.scan();
      expect(snapshot.isComplete, isTrue);
      expect(snapshot.issues, isEmpty);
      expect(snapshot.entries.map((entry) => entry.fileName), [
        'alpha.VRLZ',
        'zeta.vrlz',
      ]);
      expect(snapshot.entries.first.metadata.kind, VrlzPackageKind.builtin);
      expect(snapshot.entries.first.metadata.demoId, 'hello_vr');
      expect(snapshot.entries.last.metadata.kind, VrlzPackageKind.scene);
      final loaded = await store.load(snapshot.entries.last);
      expect(loaded.sceneBundle!.sceneBytes, triangleGlb());
      expect(loaded.source, File(snapshot.entries.last.path).uri);
      expect(
        (await store.scan()).entries.map((entry) => entry.fingerprint),
        snapshot.entries.map((entry) => entry.fingerprint),
      );
      expect(() => snapshot.entries.clear(), throwsUnsupportedError);
    },
  );

  test(
    'malformed packages are isolated while every duplicate ID is excluded',
    () async {
      await write(
        'b.vrlz',
        descriptor('org.example.duplicate', title: 'Bravo'),
      );
      await write('a.vrlz', descriptor('org.example.duplicate'));
      await write('good.vrlz', descriptor('org.example.good'));
      await write('broken.vrlz', [0, 1, 2]);
      final snapshot = await store.scan();
      expect(snapshot.isComplete, isTrue);
      expect(snapshot.entries.map((entry) => entry.metadata.id), [
        'org.example.good',
      ]);
      expect(snapshot.issues.map((issue) => issue.fileName), [
        'a.vrlz',
        'b.vrlz',
        'broken.vrlz',
      ]);
      final duplicates = snapshot.issues.where(
        (issue) => issue.kind == VrlzDiscoveryIssueKind.duplicateId,
      );
      expect(duplicates, hasLength(2));
      expect(
        duplicates.every((issue) => issue.packageId == 'org.example.duplicate'),
        isTrue,
      );
      expect(snapshot.issues.last.kind, VrlzDiscoveryIssueKind.invalidPackage);
      await expectLater(
        store.importBytes(
          descriptor('org.example.duplicate'),
          filename: 'third.vrlz',
        ),
        throwsA(discoveryFailure(VrlzDiscoveryIssueKind.duplicateId)),
      );
      expect(
        await File.fromUri(root.uri.resolve('third.vrlz')).exists(),
        isFalse,
      );
    },
  );

  test(
    'links outside the directory and linked roots are rejected',
    () async {
      final outside = await File.fromUri(
        temporary.uri.resolve('outside.vrlz'),
      ).writeAsBytes(descriptor('org.example.outside'));
      await Link.fromUri(root.uri.resolve('linked.vrlz')).create(outside.path);
      await write('good.vrlz', descriptor('org.example.good'));
      final snapshot = await store.scan();
      expect(snapshot.entries.map((entry) => entry.fileName), ['good.vrlz']);
      expect(snapshot.issues.single.kind, VrlzDiscoveryIssueKind.symbolicLink);
      final linkedRoot = Link.fromUri(temporary.uri.resolve('linked-root'));
      await linkedRoot.create(root.path);
      final linkedStore = VrlzDirectoryStore(linkedRoot.path);
      expect(
        (await linkedStore.scan()).issues.single.kind,
        VrlzDiscoveryIssueKind.symbolicLink,
      );
      await expectLater(
        linkedStore.importBytes(descriptor('org.example.new')),
        throwsA(discoveryFailure(VrlzDiscoveryIssueKind.symbolicLink)),
      );
      expect(await outside.readAsBytes(), descriptor('org.example.outside'));
    },
    skip: Platform.isWindows
        ? 'Creating links requires optional Windows privileges.'
        : false,
  );

  test(
    'fingerprints reject a valid same-size replacement even if mtime is restored',
    () async {
      final original = descriptor('org.example.changed');
      final replacement = descriptor('org.example.changed', title: 'Bravo');
      expect(replacement.length, original.length);
      final file = await write('changed.vrlz', original);
      final stamp = await file.lastModified();
      final entry = (await store.scan()).entries.single;
      await file.writeAsBytes(replacement);
      await file.setLastModified(stamp);
      await expectLater(
        store.load(entry),
        throwsA(discoveryFailure(VrlzDiscoveryIssueKind.changedFile)),
      );
      final refreshed = (await store.scan()).entries.single;
      expect((await store.load(refreshed)).title, 'Bravo');
    },
  );

  test(
    'selections cannot be reused in another directory or forge an outside path',
    () async {
      await write('good.vrlz', descriptor('org.example.good'));
      final entry = (await store.scan()).entries.single;
      final other = await Directory.fromUri(
        temporary.uri.resolve('other/'),
      ).create();
      await expectLater(
        VrlzDirectoryStore(other.path).load(entry),
        throwsA(discoveryFailure(VrlzDiscoveryIssueKind.changedFile)),
      );
      final forged = VrlzDirectoryEntry(
        rootPath: entry.rootPath,
        path: entry.path,
        fileName: '../outside.vrlz',
        metadata: entry.metadata,
        fingerprint: entry.fingerprint,
        byteLength: entry.byteLength,
      );
      await expectLater(
        store.load(forged),
        throwsA(isA<VrlzDiscoveryException>()),
      );
    },
  );

  test('a file-count overflow returns no arbitrary partial catalog', () async {
    await write('z.vrlz', descriptor('org.example.z'));
    await write('a.vrlz', descriptor('org.example.a'));
    final snapshot = await VrlzDirectoryStore(
      root.path,
      limits: const VrlzDiscoveryLimits(maxFiles: 1),
    ).scan();
    expect(snapshot.entries, isEmpty);
    expect(snapshot.isComplete, isFalse);
    expect(snapshot.issues.single.kind, VrlzDiscoveryIssueKind.directoryLimit);
  });

  test('unrelated directory entries are bounded too', () async {
    for (var i = 0; i < 4; i++) {
      await write('note$i.txt', [0]);
    }
    final snapshot = await VrlzDirectoryStore(
      root.path,
      limits: const VrlzDiscoveryLimits(maxFiles: 1, maxDirectoryEntries: 3),
    ).scan();
    expect(snapshot.isComplete, isFalse);
    expect(snapshot.issues.single.kind, VrlzDiscoveryIssueKind.directoryLimit);
  });

  test(
    'per-file failures are isolated and aggregate-byte overflow is all-or-nothing',
    () async {
      final bytes = descriptor('org.example.good');
      await write('good.vrlz', bytes);
      await write('oversize.vrlz', Uint8List(bytes.length + 1));
      final individual = await VrlzDirectoryStore(
        root.path,
        limits: VrlzDiscoveryLimits(maxFileBytes: bytes.length),
      ).scan();
      expect(individual.entries.single.fileName, 'good.vrlz');
      expect(
        individual.issues.single.kind,
        VrlzDiscoveryIssueKind.fileTooLarge,
      );
      final aggregate = await VrlzDirectoryStore(
        root.path,
        limits: VrlzDiscoveryLimits(maxTotalBytes: bytes.length),
      ).scan();
      expect(aggregate.entries, isEmpty);
      expect(aggregate.isComplete, isFalse);
      expect(
        aggregate.issues.single.kind,
        VrlzDiscoveryIssueKind.totalByteLimit,
      );
    },
  );

  test(
    'scan creates nothing; only a validated explicit import creates its directory',
    () async {
      final missing = Directory.fromUri(temporary.uri.resolve('new/packages/'));
      final freshStore = VrlzDirectoryStore(missing.path);
      final snapshot = await freshStore.scan();
      expect(snapshot.entries, isEmpty);
      expect(snapshot.issues.single.kind, VrlzDiscoveryIssueKind.unavailable);
      expect(await missing.exists(), isFalse);
      await expectLater(
        freshStore.importBytes(Uint8List.fromList([1, 2, 3])),
        throwsFormatException,
      );
      expect(await missing.exists(), isFalse);
      final imported = await freshStore.importBytes(
        descriptor('org.example.created'),
      );
      expect(await missing.exists(), isTrue);
      expect((await freshStore.load(imported)).id, 'org.example.created');
    },
  );

  test(
    'explicit imports preserve bytes and never overwrite an existing filename',
    () async {
      final original = descriptor('org.example.original');
      final entry = await store.importBytes(
        original,
        filename: 'A scene #1.vrlz',
      );
      expect(await File(entry.path).readAsBytes(), original);
      await expectLater(
        store.importBytes(
          descriptor('org.example.other'),
          filename: 'A scene #1.vrlz',
        ),
        throwsA(discoveryFailure(VrlzDiscoveryIssueKind.importConflict)),
      );
      expect(await File(entry.path).readAsBytes(), original);
      await write('empty.vrlz', []);
      await expectLater(
        store.importBytes(
          descriptor('org.example.third'),
          filename: 'empty.vrlz',
        ),
        throwsA(discoveryFailure(VrlzDiscoveryIssueKind.importConflict)),
      );
      expect(await File.fromUri(root.uri.resolve('empty.vrlz')).length(), 0);
      expect(
        (await root.list().toList()).whereType<Directory>(),
        isEmpty,
        reason:
            'Private staging directories are removed after completion/failure.',
      );
    },
  );

  test(
    'concurrent imports of one ID cannot choose two conflicting files',
    () async {
      Future<Object> attempt(String name) async {
        try {
          return await VrlzDirectoryStore(
            root.path,
          ).importBytes(descriptor('org.example.same'), filename: name);
        } catch (error) {
          return error;
        }
      }

      final results = await Future.wait([
        attempt('first.vrlz'),
        attempt('second.vrlz'),
      ]);
      expect(results.whereType<VrlzDirectoryEntry>(), hasLength(1));
      expect(
        results.whereType<VrlzDiscoveryException>().single.kind,
        VrlzDiscoveryIssueKind.duplicateId,
      );
      final snapshot = await store.scan();
      expect(snapshot.entries, hasLength(1));
      expect(snapshot.issues, isEmpty);
    },
  );

  test(
    'exclusive coordination prevents duplicate imports across two real isolates',
    () async {
      for (var i = 0; i < 10; i++) {
        await write('existing$i.vrlz', descriptor('org.example.existing$i'));
      }
      final events = ReceivePort();
      final starts = <SendPort>[];
      final outcomes = <String>[];
      final ready = Completer<void>();
      final finished = Completer<void>();
      final subscription = events.listen((message) {
        if (message is SendPort) {
          starts.add(message);
          if (starts.length == 2) ready.complete();
        } else if (message is String) {
          outcomes.add(message);
          if (outcomes.length == 2) finished.complete();
        }
      });
      final first = await Isolate.spawn(_isolatedImport, (
        events.sendPort,
        root.path,
        'first.vrlz',
      ));
      final second = await Isolate.spawn(_isolatedImport, (
        events.sendPort,
        root.path,
        'second.vrlz',
      ));
      try {
        await ready.future.timeout(const Duration(seconds: 10));
        for (final start in starts) {
          start.send(null);
        }
        await finished.future.timeout(const Duration(seconds: 20));
        expect(outcomes.where((value) => value == 'ok'), hasLength(1));
        expect(
          outcomes.where(
            (value) => value == 'importConflict' || value == 'duplicateId',
          ),
          hasLength(1),
        );
        final snapshot = await store.scan();
        expect(snapshot.issues, isEmpty);
        expect(
          snapshot.entries.where(
            (entry) => entry.metadata.id == 'org.example.isolate',
          ),
          hasLength(1),
        );
        expect(
          await File.fromUri(
            root.uri.resolve('.vrlizate-import.lock'),
          ).exists(),
          isFalse,
        );
      } finally {
        first.kill(priority: Isolate.immediate);
        second.kill(priority: Isolate.immediate);
        await subscription.cancel();
        events.close();
      }
    },
  );

  test(
    'a residual or foreign coordination marker is never reclaimed automatically',
    () async {
      final marker = await write('.vrlizate-import.lock', [1, 2, 3]);
      await expectLater(
        store.importBytes(descriptor('org.example.new')),
        throwsA(discoveryFailure(VrlzDiscoveryIssueKind.importConflict)),
      );
      expect(await marker.readAsBytes(), [1, 2, 3]);
      expect((await store.scan()).entries, isEmpty);
    },
  );

  test(
    'unsafe import filenames are rejected before creating anything',
    () async {
      for (final name in [
        '../escape.vrlz',
        '/escape.vrlz',
        'dir/file.vrlz',
        r'dir\file.vrlz',
        'data.vrz',
        'bad\u0000.vrlz',
      ]) {
        await expectLater(
          store.importBytes(descriptor('org.example.safe'), filename: name),
          throwsA(isA<VrlzDiscoveryException>()),
        );
      }
      expect(await root.list().toList(), isEmpty);
    },
  );

  test(
    'an import cannot exceed the package count or aggregate byte budgets',
    () async {
      final bytes = descriptor('org.example.one');
      await write('one.vrlz', bytes);
      final oneFile = VrlzDirectoryStore(
        root.path,
        limits: const VrlzDiscoveryLimits(maxFiles: 1),
      );
      await expectLater(
        oneFile.importBytes(descriptor('org.example.two')),
        throwsA(discoveryFailure(VrlzDiscoveryIssueKind.directoryLimit)),
      );
      final byteLimited = VrlzDirectoryStore(
        root.path,
        limits: VrlzDiscoveryLimits(maxTotalBytes: bytes.length + 1),
      );
      await expectLater(
        byteLimited.importBytes(descriptor('org.example.two')),
        throwsA(discoveryFailure(VrlzDiscoveryIssueKind.totalByteLimit)),
      );
      expect((await store.scan()).entries.map((entry) => entry.metadata.id), [
        'org.example.one',
      ]);
    },
  );
}
