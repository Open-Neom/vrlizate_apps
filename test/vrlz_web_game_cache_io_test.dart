import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_apps/vrlizate_apps_io.dart';

void main() {
  late Directory root;
  setUp(() {
    root = Directory.systemTemp.createTempSync('vrlz-web-cache-');
  });
  tearDown(() {
    root.deleteSync(recursive: true);
  });
  final a = Uint8List.fromList([1, 2, 3]),
      b = Uint8List.fromList([4, 5, 6]),
      c = Uint8List.fromList([7, 8, 9]);
  String hash(Uint8List bytes) => '${crypto.sha256.convert(bytes)}';

  test(
    'persists across instances and is usable offline without any HTTP client',
    () async {
      final cache = VrlzWebGameFileCache(root.path, maxBytes: 20);
      await cache.write(hash(a), a);
      a[0] = 1;
      final restarted = VrlzWebGameFileCache(root.path, maxBytes: 20);
      final bytes = await restarted.read(hash(a), byteLength: 3);
      expect(bytes, a);
      bytes![0] = 0;
      expect(await restarted.read(hash(a), byteLength: 3), a);
      expect(restarted.byteLength, 3);
      expect(restarted.fileCount, 1);
    },
  );
  test(
    'LRU visits retain nearest resources within the declared disk quota',
    () async {
      final cache = VrlzWebGameFileCache(root.path, maxBytes: 6);
      await cache.write(hash(a), a);
      await cache.write(hash(b), b);
      final old = DateTime.utc(2000);
      await File('${root.path}/${hash(a)}.chunk').setLastModified(old);
      await File(
        '${root.path}/${hash(b)}.chunk',
      ).setLastModified(old.add(const Duration(seconds: 1)));
      await cache.read(hash(a), byteLength: 3);
      await cache.write(hash(c), c);
      expect(cache.byteLength, 6);
      expect(cache.fileCount, 2);
      expect(await cache.read(hash(b), byteLength: 3), isNull);
      expect(await cache.read(hash(a), byteLength: 3), a);
    },
  );
  test(
    'corruption is discarded and never returned as verified offline content',
    () async {
      final cache = VrlzWebGameFileCache(root.path, maxBytes: 20);
      await cache.write(hash(a), a);
      await File('${root.path}/${hash(a)}.chunk').writeAsBytes([0, 0, 0]);
      expect(await cache.read(hash(a), byteLength: 3), isNull);
      expect(await File('${root.path}/${hash(a)}.chunk').exists(), isFalse);
      await expectLater(cache.write(hash(a), b), throwsFormatException);
      await cache.write(hash(a), a);
      expect(await cache.read(hash(a), byteLength: 2), isNull);
    },
  );
  test(
    'cache cannot read, replace or clear symlinks and preserves unrelated files',
    () async {
      final outside = File('${root.path}/outside.bin')..writeAsBytesSync(a);
      final link = Link('${root.path}/${hash(a)}.chunk');
      await link.create(outside.path);
      final cache = VrlzWebGameFileCache(root.path, maxBytes: 20);
      await expectLater(
        cache.read(hash(a), byteLength: 3),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        cache.write(hash(a), a),
        throwsA(isA<FileSystemException>()),
      );
      await cache.clear();
      expect(await outside.readAsBytes(), a);
      expect(await link.exists(), isTrue);
      await expectLater(
        cache.read('../outside', byteLength: 3),
        throwsFormatException,
      );
    },
  );
  test(
    'existing package discovery remains the only entrypoint for webgame indices',
    () async {
      // Cache payloads are intentionally not .vrlz and must never be discovered
      // as independently launchable experiences by a normal directory scan.
      final cache = VrlzWebGameFileCache(root.path, maxBytes: 20);
      await cache.write(hash(a), a);
      final snapshot = await VrlzDirectoryStore(root.path).scan();
      expect(snapshot.entries, isEmpty);
      expect(snapshot.issues, isEmpty);
    },
  );
}
