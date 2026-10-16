import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vrlizate_apps/vrlizate_apps.dart';
import 'package:vrlizate_apps/vrlizate_apps_io.dart';
import 'package:vrlizate_apps/vrlizate_apps_library.dart';

Uint8List _bytes(String id) => VrlzPackage.encodeBuiltin(
  id: id,
  title: 'Verified title',
  description: 'Verified description',
  demoId: 'hello_vr',
);

VrlzDirectoryEntry _entry(String id) => VrlzDirectoryEntry(
  rootPath: '/packages',
  path: '/packages/$id.vrlz',
  fileName: '$id.vrlz',
  metadata: VrlzPackageMetadata.fromPackage(VrlzPackage.decode(_bytes(id))),
  fingerprint: sha256.convert(_bytes(id)).toString(),
  byteLength: _bytes(id).length,
);

VrlzDirectorySnapshot _snapshot(
  String id, {
  List<VrlzDirectoryIssue> issues = const [],
}) => VrlzDirectorySnapshot(
  rootPath: '/packages',
  entries: [_entry(id)],
  issues: issues,
  isComplete: true,
);

class _Store extends VrlzDirectoryStore {
  _Store() : super('/packages');
  VrlzDirectorySnapshot snapshot = _snapshot('org.example.local');
  Future<VrlzDirectorySnapshot> Function()? scanOverride;
  Future<VrlzPackage> Function(VrlzDirectoryEntry)? loadOverride;
  final scanStarted = Completer<void>();
  final loadStarted = Completer<void>();
  int scans = 0, loads = 0, imports = 0;
  Uint8List? imported;

  @override
  Future<VrlzDirectorySnapshot> scan() {
    scans++;
    if (!scanStarted.isCompleted) scanStarted.complete();
    return scanOverride?.call() ?? Future.value(snapshot);
  }

  @override
  Future<VrlzPackage> load(VrlzDirectoryEntry entry) {
    loads++;
    if (!loadStarted.isCompleted) loadStarted.complete();
    return loadOverride?.call(entry) ??
        Future.value(VrlzPackage.decode(_bytes(entry.metadata.id)));
  }

  @override
  Future<VrlzDirectoryEntry> importBytes(
    Uint8List bytes, {
    String? filename,
  }) async {
    imports++;
    imported = Uint8List.fromList(bytes);
    final package = VrlzPackage.decode(bytes);
    snapshot = _snapshot(package.id);
    return snapshot.entries.single;
  }
}

String _index(String id, Uint8List bytes) => jsonEncode({
  'formatVersion': 1,
  'packages': [
    {
      'id': id,
      'title': 'Unverified index title',
      'url': 'item.vrlz',
      'sha256': sha256.convert(bytes).toString(),
    },
  ],
});

void main() {
  final indexUri = Uri.parse('https://example.org/packages/index.json');
  final packageUri = indexUri.resolve('item.vrlz');

  test(
    'refresh uses scanner metadata/issues without installing or launching',
    () async {
      final store = _Store()
        ..snapshot = _snapshot(
          'org.example.local',
          issues: const [
            VrlzDirectoryIssue(
              path: '/packages/bad.vrlz',
              fileName: 'bad.vrlz',
              kind: VrlzDiscoveryIssueKind.invalidPackage,
              message: 'Invalid package',
            ),
          ],
        );
      var exampleCalls = 0;
      final controller = VrlzLibraryController(
        openDirectory: () async => store,
        addExamples: (_) async {
          exampleCalls++;
        },
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      expect(controller.location, '/packages');
      expect(controller.items.single.id, 'org.example.local');
      expect(controller.items.single.kind, VrlzPackageKind.builtin);
      expect(controller.items.single.demoId, 'hello_vr');
      expect(controller.issues, ['bad.vrlz: Invalid package']);
      expect(controller.isComplete, isTrue);
      expect(controller.isWeb, isFalse);
      expect(controller.busy, isFalse);
      expect(exampleCalls, 0);
      expect(store.imports, 0);
      expect(store.loads, 0);
      expect(() => controller.items.clear(), throwsUnsupportedError);
      expect(() => controller.issues.clear(), throwsUnsupportedError);
    },
  );

  test(
    'overlapping refresh and install requests do not duplicate work',
    () async {
      final gate = Completer<VrlzDirectorySnapshot>();
      final store = _Store()..scanOverride = () => gate.future;
      var installs = 0;
      final controller = VrlzLibraryController(
        openDirectory: () async => store,
        addExamples: (_) async {
          installs++;
        },
      );
      addTearDown(controller.dispose);
      final pending = controller.refresh();
      await store.scanStarted.future;
      expect(controller.busy, isTrue);
      await controller.refresh();
      await controller.installExamples();
      await expectLater(controller.load('anything'), throwsStateError);
      expect(store.scans, 1);
      expect(installs, 0);
      gate.complete(store.snapshot);
      await pending;
      expect(controller.busy, isFalse);
    },
  );

  test(
    'incomplete local scans cannot launch a potentially ambiguous ID',
    () async {
      final store = _Store()
        ..snapshot = VrlzDirectorySnapshot(
          rootPath: '/packages',
          entries: [_entry('org.example.local')],
          issues: const [
            VrlzDirectoryIssue(
              path: '/packages/unknown.vrlz',
              fileName: 'unknown.vrlz',
              kind: VrlzDiscoveryIssueKind.inaccessible,
              message: 'Cannot inspect another package',
            ),
          ],
          isComplete: false,
        );
      final controller = VrlzLibraryController(
        openDirectory: () async => store,
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      expect(controller.items, hasLength(1));
      await expectLater(
        controller.load(controller.items.single.key),
        throwsStateError,
      );
      expect(store.loads, 0);
      expect(controller.error, contains('incomplete'));
      store.snapshot = _snapshot('org.example.local');
      await controller.refresh();
      expect(
        (await controller.load(controller.items.single.key)).id,
        'org.example.local',
      );
      expect(store.loads, 1);
    },
  );

  test('a failed directory provider is visible and can be retried', () async {
    final store = _Store();
    var attempts = 0;
    final controller = VrlzLibraryController(
      openDirectory: () async {
        attempts++;
        if (attempts == 1) throw StateError('Folder unavailable');
        return store;
      },
    );
    addTearDown(controller.dispose);
    await controller.refresh();
    expect(controller.error, contains('Folder unavailable'));
    expect(controller.busy, isFalse);
    expect(controller.isComplete, isFalse);
    await controller.refresh();
    expect(attempts, 2);
    expect(controller.error, isNull);
    expect(controller.items.single.id, 'org.example.local');
  });

  test(
    'loading revalidates the selected scanner entry and propagates failures',
    () async {
      final store = _Store();
      final controller = VrlzLibraryController(
        openDirectory: () async => store,
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      final key = controller.items.single.key;
      store.loadOverride = (entry) async {
        expect(entry.fingerprint, store.snapshot.entries.single.fingerprint);
        throw const VrlzDiscoveryException(
          VrlzDiscoveryIssueKind.changedFile,
          'Refresh changed file',
        );
      };
      await expectLater(
        controller.load(key),
        throwsA(isA<VrlzDiscoveryException>()),
      );
      expect(store.loads, 1);
      expect(controller.error, contains('Refresh changed file'));
      expect(controller.busy, isFalse);
      await expectLater(controller.load('missing'), throwsStateError);
      expect(
        store.loads,
        1,
        reason: 'A stale key must never resolve by its display title.',
      );
    },
  );

  test(
    'source switching discards a late local refresh and returns to local on request',
    () async {
      final gate = Completer<VrlzDirectorySnapshot>();
      final store = _Store()..scanOverride = () => gate.future;
      final webBytes = _bytes('org.example.web');
      final client = MockClient(
        (request) async =>
            http.Response(_index('org.example.web', webBytes), 200),
      );
      final catalogLoader = VrlzWebCatalogLoader(client: client);
      addTearDown(catalogLoader.close);
      final controller = VrlzLibraryController(
        openDirectory: () async => store,
        catalogLoader: catalogLoader,
      );
      addTearDown(controller.dispose);
      final oldRefresh = controller.refresh();
      await store.scanStarted.future;
      await controller.useWebCatalog(indexUri);
      expect(controller.isWeb, isTrue);
      expect(controller.items.single.id, 'org.example.web');
      expect(controller.items.single.kind, isNull);
      gate.complete(store.snapshot);
      await oldRefresh;
      expect(controller.items.single.id, 'org.example.web');
      expect(controller.error, isNull);
      await controller.useLocalDirectory();
      expect(controller.isWeb, isFalse);
      expect(controller.items.single.id, 'org.example.local');
    },
  );

  test(
    'web card becomes verified only after SHA and ID checked package load',
    () async {
      final webBytes = _bytes('org.example.web');
      final client = MockClient(
        (request) async => request.url == indexUri
            ? http.Response(_index('org.example.web', webBytes), 200)
            : http.Response.bytes(webBytes, 200),
      );
      final loader = VrlzWebCatalogLoader(client: client);
      addTearDown(loader.close);
      var directories = 0;
      final controller = VrlzLibraryController(
        openDirectory: () async {
          directories++;
          return _Store();
        },
        catalogLoader: loader,
      );
      addTearDown(controller.dispose);
      await controller.useWebCatalog(indexUri);
      expect(controller.items.single.title, 'Unverified index title');
      expect(controller.items.single.kind, isNull);
      expect(controller.items.single.demoId, isNull);
      final package = await controller.load(controller.items.single.key);
      expect(package.id, 'org.example.web');
      expect(controller.items.single.title, 'Verified title');
      expect(controller.items.single.description, 'Verified description');
      expect(controller.items.single.kind, VrlzPackageKind.builtin);
      expect(controller.items.single.demoId, 'hello_vr');
      expect(directories, 0);
    },
  );

  test(
    'a load finishing after source switch cannot launch the old selection',
    () async {
      final gate = Completer<VrlzPackage>();
      final store = _Store()..loadOverride = (_) => gate.future;
      final webBytes = _bytes('org.example.web');
      final loader = VrlzWebCatalogLoader(
        client: MockClient(
          (_) async => http.Response(_index('org.example.web', webBytes), 200),
        ),
      );
      addTearDown(loader.close);
      final controller = VrlzLibraryController(
        openDirectory: () async => store,
        catalogLoader: loader,
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      final pending = controller.load(controller.items.single.key);
      final rejected = expectLater(pending, throwsStateError);
      await store.loadStarted.future;
      await controller.useWebCatalog(indexUri);
      gate.complete(VrlzPackage.decode(_bytes('org.example.local')));
      await rejected;
      expect(controller.items.single.id, 'org.example.web');
      expect(controller.items.single.kind, isNull);
      expect(controller.error, isNull);
    },
  );

  test(
    'explicit URL import and examples select the refreshed local library',
    () async {
      final store = _Store();
      final packageBytes = _bytes('org.example.downloaded');
      final packageLoader = VrlzPackageLoader(
        client: MockClient((_) async => http.Response.bytes(packageBytes, 200)),
      );
      addTearDown(packageLoader.close);
      var installations = 0;
      final controller = VrlzLibraryController(
        openDirectory: () async => store,
        packageLoader: packageLoader,
        addExamples: (target) async {
          installations++;
          await target.importBytes(_bytes('org.example.sample'));
        },
      );
      addTearDown(controller.dispose);
      await controller.importFromUrl(packageUri);
      expect(store.imports, 1);
      expect(VrlzPackage.decode(store.imported!).id, 'org.example.downloaded');
      expect(controller.items.single.id, 'org.example.downloaded');
      expect(controller.isWeb, isFalse);
      expect(installations, 0);
      await controller.installExamples();
      expect(installations, 1);
      expect(controller.items.single.id, 'org.example.sample');
    },
  );

  test(
    'failed import does not write a package or leave the controller busy',
    () async {
      final store = _Store();
      final loader = VrlzPackageLoader(
        client: MockClient((_) async => http.Response('invalid', 200)),
      );
      addTearDown(loader.close);
      final controller = VrlzLibraryController(
        openDirectory: () async => store,
        packageLoader: loader,
      );
      addTearDown(controller.dispose);
      await controller.importFromUrl(packageUri);
      expect(store.imports, 0);
      expect(controller.error, isNotNull);
      expect(controller.busy, isFalse);
    },
  );

  test(
    'dispose suppresses pending notifications without closing borrowed loaders',
    () async {
      final gate = Completer<VrlzDirectorySnapshot>();
      final store = _Store()..scanOverride = () => gate.future;
      final bytes = _bytes('org.example.borrowed');
      final packages = VrlzPackageLoader(
        client: MockClient((_) async => http.Response.bytes(bytes, 200)),
      );
      final catalogs = VrlzWebCatalogLoader(
        client: MockClient(
          (_) async =>
              http.Response(_index('org.example.borrowed', bytes), 200),
        ),
      );
      addTearDown(packages.close);
      addTearDown(catalogs.close);
      final controller = VrlzLibraryController(
        openDirectory: () async => store,
        packageLoader: packages,
        catalogLoader: catalogs,
      );
      var notifications = 0;
      controller.addListener(() => notifications++);
      final refresh = controller.refresh();
      await store.scanStarted.future;
      final before = notifications;
      controller.dispose();
      gate.complete(store.snapshot);
      await refresh;
      expect(notifications, before);
      expect(controller.items, isEmpty);
      expect((await packages.load(packageUri)).id, 'org.example.borrowed');
      expect(
        (await catalogs.load(indexUri)).entries.single.id,
        'org.example.borrowed',
      );
      await expectLater(controller.load('anything'), throwsStateError);
      await controller.refresh();
      expect(store.scans, 1);
    },
  );

  test(
    'dispose rejects a pending load rather than delivering data to a removed host',
    () async {
      final gate = Completer<VrlzPackage>();
      final store = _Store()..loadOverride = (_) => gate.future;
      final controller = VrlzLibraryController(
        openDirectory: () async => store,
      );
      await controller.refresh();
      final load = controller.load(controller.items.single.key);
      final rejected = expectLater(load, throwsStateError);
      await store.loadStarted.future;
      controller.dispose();
      gate.complete(VrlzPackage.decode(_bytes('org.example.local')));
      await rejected;
    },
  );
}
