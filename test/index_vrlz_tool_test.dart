import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_apps/vrlizate_apps.dart';

import '../tool/index_vrlz.dart';
import 'support/vrz_fixture.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('vrlz-index-test-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  Future<File> addPackage(String name, String id) async {
    final file = File.fromUri(directory.uri.resolve(Uri.encodeComponent(name)));
    await file.writeAsBytes(
      VrlzPackage.encodeBuiltin(
        id: id,
        title: 'Room $id',
        demoId: 'flutter_scene_room',
      ),
    );
    return file;
  }

  test(
    'indexes flat packages with encoded filenames and exact file hashes',
    () async {
      final special = await addPackage('A #50%.vrlz', 'org.example.special');
      final colon = await addPackage('z:room.vrlz', 'org.example.colon');
      final scene = File.fromUri(directory.uri.resolve('scene.vrlz'));
      await scene.writeAsBytes(fixtureBundle());
      final nested = await Directory.fromUri(
        directory.uri.resolve('nested/'),
      ).create();
      await File.fromUri(
        nested.uri.resolve('invalid.vrlz'),
      ).writeAsString('Ignored nested file');
      await File.fromUri(
        directory.uri.resolve('README.txt'),
      ).writeAsString('Not a package');

      final file = await writeVrlzIndex(directory.path);
      expect(file.uri.pathSegments.last, 'catalog.json');
      expect(
        await file.parent.resolveSymbolicLinks(),
        await directory.resolveSymbolicLinks(),
      );
      final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      expect(raw.keys, unorderedEquals(['formatVersion', 'packages']));
      final listed = raw['packages'] as List;
      expect(listed, hasLength(3));
      expect(listed.first['url'], 'A%20%2350%25.vrlz');
      expect(listed.last['url'], 'z%3Aroom.vrlz');
      final catalog = VrlzWebCatalog.decode(
        await file.readAsBytes(),
        source: Uri.parse('https://example.org/packages/catalog.json'),
      );
      for (final source in [special, colon, scene]) {
        final name = source.uri.pathSegments.last;
        final entry = catalog.entries.singleWhere(
          (entry) => entry.url.pathSegments.last == name,
        );
        expect(
          entry.sha256,
          sha256.convert(await source.readAsBytes()).toString(),
        );
        expect(entry.url.scheme, 'https');
        expect(entry.url.hasFragment, isFalse);
      }
    },
  );

  test('preserves existing output unless force is explicit', () async {
    await addPackage('room.vrlz', 'org.example.room');
    final output = File.fromUri(directory.uri.resolve('catalog.json'));
    await output.writeAsString('Existing index bytes');
    await expectLater(
      writeVrlzIndex(directory.path),
      throwsA(isA<FileSystemException>()),
    );
    expect(await output.readAsString(), 'Existing index bytes');
    await writeVrlzIndex(directory.path, force: true);
    expect(
      VrlzWebCatalog.decode(
        await output.readAsBytes(),
        source: Uri.parse('https://example.org/catalog.json'),
      ).entries.single.id,
      'org.example.room',
    );
  });

  test('invalid package prevents replacement even with force', () async {
    await addPackage('valid.vrlz', 'org.example.room');
    await File.fromUri(
      directory.uri.resolve('broken.vrlz'),
    ).writeAsString('broken');
    final output = File.fromUri(directory.uri.resolve('catalog.json'));
    await output.writeAsString('Keep this index');
    await expectLater(
      writeVrlzIndex(directory.path, force: true),
      throwsStateError,
    );
    expect(await output.readAsString(), 'Keep this index');
  });

  test(
    'duplicate IDs and incomplete scans never publish a partial index',
    () async {
      await addPackage('a.vrlz', 'org.example.same');
      await addPackage('b.vrlz', 'org.example.same');
      await expectLater(writeVrlzIndex(directory.path), throwsStateError);
      expect(
        await File.fromUri(directory.uri.resolve('catalog.json')).exists(),
        isFalse,
      );
      final missing = Directory.fromUri(directory.uri.resolve('absent/'));
      await expectLater(writeVrlzIndex(missing.path), throwsStateError);
      expect(await missing.exists(), isFalse);
    },
  );

  test(
    'custom output retains relative filenames and empty folders are valid',
    () async {
      final staged = File.fromUri(directory.uri.resolve('staging/web.json'));
      await writeVrlzIndex(directory.path, outputPath: staged.path);
      final catalog = VrlzWebCatalog.decode(
        await staged.readAsBytes(),
        source: Uri.parse('https://example.org/catalog.json'),
      );
      expect(catalog.entries, isEmpty);
      await addPackage('room.vrlz', 'org.example.room');
      await writeVrlzIndex(
        directory.path,
        outputPath: staged.path,
        force: true,
      );
      final json =
          jsonDecode(await staged.readAsString()) as Map<String, dynamic>;
      expect(json['packages'][0]['url'], 'room.vrlz');
    },
  );

  test(
    'force cannot overwrite a package or follow an output symlink',
    () async {
      final package = await addPackage('room.vrlz', 'org.example.room');
      final original = await package.readAsBytes();
      await expectLater(
        writeVrlzIndex(directory.path, outputPath: package.path, force: true),
        throwsA(isA<FileSystemException>()),
      );
      expect(await package.readAsBytes(), original);
      final target = File.fromUri(directory.uri.resolve('original.json'));
      await target.writeAsString('Keep target');
      final link = Link.fromUri(directory.uri.resolve('catalog.json'));
      await link.create(target.path);
      await expectLater(
        writeVrlzIndex(directory.path, force: true),
        throwsA(isA<FileSystemException>()),
      );
      expect(await target.readAsString(), 'Keep target');
    },
    skip: Platform.isWindows,
  );
}
