import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_apps/vrlizate_apps.dart';

import '../tool/pack_vrlz.dart';
import 'support/nes_fixture.dart';

void main() {
  late Directory directory;
  late File rom, license, output;
  late List<String> arguments;
  setUp(() async {
    exitCode = 0;
    directory = await Directory.systemTemp.createTemp('pack-nes-test-');
    rom = File('${directory.path}/game.nes');
    license = File('${directory.path}/LICENSE.txt');
    output = File('${directory.path}/game.vrlz');
    await rom.writeAsBytes(nromFixture());
    await license.writeAsString(nesFixtureLicense);
    arguments = [
      '--nes',
      rom.path,
      output.path,
      '--id',
      'org.community.demo',
      '--title',
      'Mi demo comunitario',
      '--description',
      'Demo NES para probar en la plaza',
      '--license-file',
      license.path,
      '--source-url',
      'https://example.org/community/demo',
    ];
  });
  tearDown(() async {
    exitCode = 0;
    await directory.delete(recursive: true);
  });

  test(
    'CLI produces an independent NES package with complete provenance',
    () async {
      await packVrlz(arguments);
      expect(exitCode, 0);
      final package = VrlzPackage.decode(await output.readAsBytes());
      expect(package.kind, VrlzPackageKind.nes);
      expect(package.id, 'org.community.demo');
      expect(package.title, 'Mi demo comunitario');
      expect(package.nesBundle!.romBytes, await rom.readAsBytes());
      expect(package.nesBundle!.manifest.license, nesFixtureLicense);
      expect(
        package.nesBundle!.manifest.sourceUrl,
        'https://example.org/community/demo',
      );
      expect(package.builtinManifest, isNull);
    },
  );

  test(
    'packs multi-mapper cartridges and rejects unsupported arcade headers',
    () async {
      final unrom = nromFixture(prgBanks: 8)..[6] = 0x20;
      await rom.writeAsBytes(unrom);
      await packVrlz(arguments);
      expect(exitCode, 0);
      expect(await output.exists(), isTrue);
      await output.delete();

      final vsArcade = nromFixture()..[7] = 0x01;
      await rom.writeAsBytes(vsArcade);
      await packVrlz(arguments);
      expect(exitCode, 1);
      expect(await output.exists(), isFalse);
    },
  );

  test('requires a license file and HTTPS provenance', () async {
    arguments.removeRange(
      arguments.indexOf('--license-file'),
      arguments.indexOf('--license-file') + 2,
    );
    await packVrlz(arguments);
    expect(exitCode, 1);
    expect(await output.exists(), isFalse);
    exitCode = 0;
    arguments.addAll(['--license-file', license.path]);
    arguments[arguments.indexOf('--source-url') + 1] =
        'http://example.org/demo';
    await packVrlz(arguments);
    expect(exitCode, 1);
    expect(await output.exists(), isFalse);
  });

  test('never overwrites a preexisting package', () async {
    await output.writeAsString('keep me');
    await packVrlz(arguments);
    expect(exitCode, 1);
    expect(await output.readAsString(), 'keep me');
  });

  test('rejects conflicting runtime and irrelevant camera flags', () async {
    await packVrlz([...arguments, '--builtin', 'nes_vr']);
    expect(exitCode, 1);
    expect(await output.exists(), isFalse);
    exitCode = 0;
    await packVrlz([...arguments, '--camera-position', '0,1,2']);
    expect(exitCode, 1);
    expect(await output.exists(), isFalse);
  });

  test('rejects oversized notices before writing output', () async {
    await license.writeAsString('x' * (VrlzNesManifest.maxLicenseBytes + 1));
    await packVrlz(arguments);
    expect(exitCode, 1);
    expect(await output.exists(), isFalse);
  });
}
