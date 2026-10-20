import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_apps/vrlizate_apps.dart';
import '../tool/pack_webgame.dart' as tool;

void main() {
  late Directory root, build, content;
  late File output;
  setUp(() {
    root = Directory.systemTemp.createTempSync('pack-webgame-');
    build = Directory('${root.path}/build')..createSync();
    File('${build.path}/index.html').writeAsStringSync(
      '<html><head><base href="/"></head><body>Game</body></html>',
    );
    File('${build.path}/main.dart.js').writeAsStringSync('window.ready=true;');
    Directory('${build.path}/assets/maps').createSync(recursive: true);
    File('${build.path}/assets/maps/area.json').writeAsStringSync('{"area":1}');
    content = Directory('${root.path}/content');
    output = File('${root.path}/game.vrlz');
  });
  tearDown(() => root.deleteSync(recursive: true));
  Future<VrlzWebGameManifest> pack({Object? units, Object? requirements}) =>
      tool.packWebGame(
        buildRoot: build,
        output: output,
        contentOutput: content,
        contentBaseUrl: 'https://games.example/immutable-build/',
        id: 'org.example.webgame',
        title: 'Web fixture',
        revision: '123',
        controllerProfile: 'dpad',
        license: 'MIT',
        assetNotice: 'Original test resources.',
        sourceUrl: 'https://github.com/example/game',
        licenseUrl: 'https://github.com/example/game/blob/123/LICENSE',
        sourceArchiveUrl: 'https://games.example/sources/123.zip',
        unitsJson: units,
        requirementsJson: requirements,
      );
  test(
    'normalizes a copied base before hashing and leaves original build untouched',
    () async {
      final manifest = await pack();
      expect(
        await File('${build.path}/index.html').readAsString(),
        contains('href="/"'),
      );
      final html = await File('${content.path}/index.html').readAsBytes();
      expect(
        await File('${content.path}/index.html').readAsString(),
        contains('href="./"'),
      );
      expect(
        manifest.file('index.html').sha256,
        '${crypto.sha256.convert(html)}',
      );
      expect(manifest.units.first.startup, isTrue);
      expect(manifest.units.first.files.map((file) => file.path), [
        'index.html',
        'main.dart.js',
      ]);
      expect(
        manifest.unit('resources').files.single.path,
        'assets/maps/area.json',
      );
      final package = VrlzPackage.decode(await output.readAsBytes());
      expect(package.kind, VrlzPackageKind.webgame);
      expect(package.webGameManifest!.revision, '123');
      await expectLater(pack(), throwsA(isA<FileSystemException>()));
    },
  );
  test(
    'explicit level partitions must cover exact known files without guessing',
    () async {
      final manifest = await pack(
        units: [
          {
            'id': 'start',
            'startup': true,
            'paths': ['index.html', 'main.dart.js'],
          },
          {
            'id': 'authored_first_level',
            'startup': false,
            'paths': ['assets/maps/area.json'],
          },
        ],
      );
      expect(manifest.unit('authored_first_level').startup, isFalse);
      expect(manifest.units, hasLength(2));
    },
  );
  test(
    'packaging includes bounded requirements without publishing invalid claims',
    () async {
      await expectLater(pack(requirements: ['webgl3']), throwsFormatException);
      expect(await output.exists(), isFalse);
      expect(await content.exists(), isFalse);
      final manifest = await pack(requirements: ['wasm-gc', 'webgl2']);
      expect(manifest.requirements, ['wasm-gc', 'webgl2']);
      final decoded = VrlzPackage.decode(await output.readAsBytes());
      expect(decoded.webGameManifest!.requirements, manifest.requirements);
    },
  );
  test(
    'CLI reads requirements JSON and preserves it in the generated index',
    () async {
      final requirements = File('${root.path}/requirements.json');
      await requirements.writeAsString(
        jsonEncode(['wasm-gc', 'cross-origin-isolation']),
      );
      final notice = File('${root.path}/assets-notice.txt');
      await notice.writeAsString('Original test resources.');
      await tool.main([
        build.path,
        output.path,
        '--content-output',
        content.path,
        '--content-base-url',
        'https://games.example/build/',
        '--id',
        'org.example.webgame',
        '--title',
        'CLI fixture',
        '--revision',
        '123',
        '--controller-profile',
        'chess',
        '--license',
        'MIT',
        '--asset-notice-file',
        notice.path,
        '--source-url',
        'https://github.com/example/game',
        '--license-url',
        'https://github.com/example/game/blob/123/LICENSE',
        '--source-archive-url',
        'https://games.example/source/123.zip',
        '--requirements-json',
        requirements.path,
      ]);
      expect(await output.exists(), isTrue);
      expect(
        VrlzPackage.decode(
          await output.readAsBytes(),
        ).webGameManifest!.requirements,
        ['wasm-gc', 'cross-origin-isolation'],
      );
    },
  );
  test('invalid units publish neither descriptor nor content', () async {
    await expectLater(
      pack(
        units: [
          {
            'id': 'start',
            'startup': true,
            'paths': ['index.html'],
          },
        ],
      ),
      throwsFormatException,
    );
    expect(await output.exists(), isFalse);
    expect(await content.exists(), isFalse);
  });
  test('rejects symlinked build resources before writing a package', () async {
    await Link(
      '${build.path}/assets/link.js',
    ).create('${build.path}/main.dart.js');
    await expectLater(pack(), throwsA(isA<FileSystemException>()));
    expect(await output.exists(), isFalse);
    expect(await content.exists(), isFalse);
  });
}
