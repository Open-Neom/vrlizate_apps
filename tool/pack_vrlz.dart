import 'dart:io';
import 'dart:typed_data';

import 'package:vrlizate_apps/vrlizate_apps.dart';

Future<void> main(List<String> arguments) => packVrlz(arguments);

/// Shared with the legacy command so old scene automation keeps working.
Future<void> packVrlz(
  List<String> arguments, {
  bool allowLegacyExtension = false,
}) async {
  if (arguments.contains('--help') || arguments.isEmpty) {
    stdout.writeln(
      'Usage:\n'
      '  dart run tool/pack_vrlz.dart INPUT.glb OUTPUT.vrlz '
      '--id org.example.scene --title "Scene" '
      '[--description "Text"] [--camera-position 0,1.6,6] '
      '[--camera-target 0,1,-6]\n'
      '  dart run tool/pack_vrlz.dart --builtin DEMO_ID OUTPUT.vrlz '
      '--id org.example.demo --title "Demo" [--description "Text"]\n'
      '  dart run tool/pack_vrlz.dart --nes INPUT.nes OUTPUT.vrlz '
      '--id org.example.homebrew --title "Homebrew" '
      '--license-file LICENSE.txt --source-url https://example.org/source '
      '[--description "Text"]\n'
      'Builtin descriptors reference demos already compiled into the host; '
      'they never include or download code. NES packages require an authorized '
      'NROM cartridge; the license declaration does not establish rights.',
    );
    if (arguments.isEmpty) exitCode = 64;
    return;
  }
  try {
    final options = <String, String>{};
    final positional = <String>[];
    const allowed = {
      '--id',
      '--title',
      '--description',
      '--camera-position',
      '--camera-target',
      '--builtin',
      '--nes',
      '--license-file',
      '--source-url',
    };
    for (var i = 0; i < arguments.length; i++) {
      final argument = arguments[i];
      if (argument.startsWith('--')) {
        if (!allowed.contains(argument) ||
            options.containsKey(argument) ||
            i + 1 >= arguments.length ||
            arguments[i + 1].startsWith('--')) {
          throw const FormatException(
            'Unknown, duplicate or incomplete option.',
          );
        }
        options[argument] = arguments[++i];
      } else {
        positional.add(argument);
      }
    }
    final builtin = options['--builtin'];
    final nes = options['--nes'];
    if (builtin != null && nes != null) {
      throw const FormatException('Choose --builtin or --nes, not both.');
    }
    if (positional.length != (builtin == null && nes == null ? 2 : 1) ||
        !options.containsKey('--id') ||
        !options.containsKey('--title')) {
      throw const FormatException(
        'Provide an output path, --id and --title, plus INPUT.glb, '
        '--builtin DEMO_ID or --nes INPUT.nes.',
      );
    }
    if ((builtin != null || nes != null) &&
        (options.containsKey('--camera-position') ||
            options.containsKey('--camera-target'))) {
      throw const FormatException('Only scene packages contain a camera.');
    }
    if (nes == null &&
        (options.containsKey('--license-file') ||
            options.containsKey('--source-url'))) {
      throw const FormatException(
        '--license-file and --source-url require --nes.',
      );
    }
    if (nes != null &&
        (!options.containsKey('--license-file') ||
            !options.containsKey('--source-url'))) {
      throw const FormatException(
        'NES packages require --license-file and --source-url.',
      );
    }
    final output = File(positional.last);
    final extension = output.path.toLowerCase();
    if (!extension.endsWith('.vrlz') &&
        !(allowLegacyExtension &&
            builtin == null &&
            nes == null &&
            extension.endsWith('.vrz'))) {
      throw const FormatException('New packages must use the .vrlz extension.');
    }
    if (await output.exists()) {
      throw const FileSystemException(
        'Output already exists; choose a new path.',
      );
    }
    final description = options['--description'] ?? '';
    final bytes = builtin != null
        ? VrlzPackage.encodeBuiltin(
            id: options['--id']!,
            title: options['--title']!,
            description: description,
            demoId: builtin,
          )
        : nes != null
        ? await _encodeNes(nes, options, description)
        : await _encodeScene(positional.first, options, description);
    await output.parent.create(recursive: true);
    await output.create(exclusive: true);
    await output.writeAsBytes(bytes, flush: true);
    final package = VrlzPackage.decode(bytes);
    stdout.writeln(
      '${output.path}: ${bytes.length} bytes; validated VRLZ ${package.kind.name}.',
    );
  } on Object catch (error) {
    stderr.writeln('Cannot pack VRLZ: $error');
    exitCode = 1;
  }
}

Future<Uint8List> _encodeNes(
  String path,
  Map<String, String> options,
  String description,
) async {
  final input = File(path);
  final license = File(options['--license-file']!);
  if (await input.length() > VrlzNesBundle.maxRomBytes) {
    throw const FormatException('Input exceeds the supported NES ROM size.');
  }
  if (await license.length() > VrlzNesManifest.maxLicenseBytes) {
    throw const FormatException('NES license notice exceeds 16 KiB.');
  }
  return VrlzPackage.encodeNes(
    romBytes: await input.readAsBytes(),
    id: options['--id']!,
    title: options['--title']!,
    description: description,
    license: await license.readAsString(),
    sourceUrl: options['--source-url']!,
  );
}

Future<Uint8List> _encodeScene(
  String path,
  Map<String, String> options,
  String description,
) async {
  final input = File(path);
  if (await input.length() > VrlzPackage.maxBytes) {
    throw const FormatException('Input exceeds 32 MiB.');
  }
  List<double> vector(String flag, List<double> fallback) =>
      options[flag]?.split(',').map(double.parse).toList() ?? fallback;
  return VrzBundle.encode(
    sceneBytes: await input.readAsBytes(),
    id: options['--id']!,
    title: options['--title']!,
    description: description,
    cameraPosition: vector('--camera-position', [0, 1.6, 6]),
    cameraTarget: vector('--camera-target', [0, 1, -6]),
  );
}
