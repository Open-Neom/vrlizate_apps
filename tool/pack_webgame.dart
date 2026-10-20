import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart' as crypto;
import 'package:vrlizate_apps/vrlizate_apps.dart';

const _usage =
    'Usage: dart --packages=.dart_tool/package_config.json tool/pack_webgame.dart '
    'BUILD_ROOT OUTPUT.vrlz --content-output DIRECTORY --content-base-url HTTPS_DIRECTORY/ '
    '--id org.example.game --title TITLE --revision REVISION --controller-profile dpad '
    '--license SPDX --asset-notice-file FILE --source-url HTTPS_URL --license-url HTTPS_URL '
    '--source-archive-url HTTPS_URL [--description TEXT] [--entrypoint index.html] '
    '[--units-json FILE] [--controls-json FILE] [--network-origins-json FILE] [--requirements-json FILE]\n'
    'Use a release web build with --no-web-resources-cdn. No deployment is performed. '
    'All outputs must be new; the HTML base is normalized in a staged copy before hashing. '
    'Default units are startup bootstrap and on-demand resources, not inferred story levels.';

Future<void> main(List<String> arguments) async {
  if (arguments.contains('--help')) {
    stdout.writeln(_usage);
    return;
  }
  try {
    final positional = <String>[], options = <String, String>{};
    const allowed = {
      '--content-output',
      '--content-base-url',
      '--id',
      '--title',
      '--revision',
      '--controller-profile',
      '--license',
      '--asset-notice-file',
      '--source-url',
      '--license-url',
      '--source-archive-url',
      '--description',
      '--entrypoint',
      '--units-json',
      '--controls-json',
      '--network-origins-json',
      '--requirements-json',
      '--viewport-width',
      '--viewport-height',
    };
    for (var i = 0; i < arguments.length; i++) {
      final item = arguments[i];
      if (item.startsWith('--')) {
        if (!allowed.contains(item) ||
            options.containsKey(item) ||
            i + 1 >= arguments.length ||
            arguments[i + 1].startsWith('--')) {
          throw const FormatException(
            'Unknown, duplicate or incomplete option.',
          );
        }
        options[item] = arguments[++i];
      } else {
        positional.add(item);
      }
    }
    String required(String key) =>
        options[key] ?? (throw FormatException('Missing $key.'));
    if (positional.length != 2) {
      throw const FormatException('Supply build root and output .vrlz.');
    }
    Object? jsonOption(String key) {
      if (options[key] == null) return null;
      final value = jsonDecode(File(options[key]!).readAsStringSync());
      if (key == '--requirements-json' && value is! List) {
        throw const FormatException('Requirements JSON must be a list.');
      }
      return value;
    }

    final manifest = await packWebGame(
      buildRoot: Directory(positional[0]),
      output: File(positional[1]),
      contentOutput: Directory(required('--content-output')),
      contentBaseUrl: required('--content-base-url'),
      id: required('--id'),
      title: required('--title'),
      revision: required('--revision'),
      controllerProfile: required('--controller-profile'),
      license: required('--license'),
      assetNotice: await File(required('--asset-notice-file')).readAsString(),
      sourceUrl: required('--source-url'),
      licenseUrl: required('--license-url'),
      sourceArchiveUrl: required('--source-archive-url'),
      description: options['--description'] ?? '',
      entrypoint: options['--entrypoint'] ?? 'index.html',
      unitsJson: jsonOption('--units-json'),
      controlsJson: jsonOption('--controls-json'),
      networkOriginsJson: jsonOption('--network-origins-json'),
      requirementsJson: jsonOption('--requirements-json'),
      viewportWidth: int.parse(options['--viewport-width'] ?? '1280'),
      viewportHeight: int.parse(options['--viewport-height'] ?? '720'),
    );
    stdout.writeln(
      'Validated ${manifest.files.length} web files / ${manifest.byteLength} bytes in ${manifest.units.length} units.',
    );
    stdout.writeln(
      'Index: ${File(positional[1]).absolute.path}; verified staged content: ${Directory(required('--content-output')).absolute.path}. Nothing deployed.',
    );
  } on FormatException catch (error) {
    stderr.writeln('${error.message}\n$_usage');
    exitCode = 64;
  } on Object catch (error) {
    stderr.writeln('Cannot package webgame: $error');
    exitCode = 1;
  }
}

/// Captures a local release build into an independent immutable content folder.
/// Declared unit memberships must cover every file exactly once. An author can
/// name real level groups explicitly; filenames alone never imply game levels.
Future<VrlzWebGameManifest> packWebGame({
  required Directory buildRoot,
  required File output,
  required Directory contentOutput,
  required String contentBaseUrl,
  required String id,
  required String title,
  required String revision,
  required String controllerProfile,
  required String license,
  required String assetNotice,
  required String sourceUrl,
  required String licenseUrl,
  required String sourceArchiveUrl,
  String description = '',
  String entrypoint = 'index.html',
  Object? unitsJson,
  Object? controlsJson,
  Object? networkOriginsJson,
  Object? requirementsJson,
  int viewportWidth = 1280,
  int viewportHeight = 720,
}) async {
  VrlzWebGameManifest.validatePath(entrypoint);
  if (!output.path.endsWith('.vrlz')) {
    throw const FormatException('Output requires .vrlz extension.');
  }
  if (await FileSystemEntity.type(buildRoot.path, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw const FileSystemException('Build root must be a regular directory.');
  }
  if (await FileSystemEntity.type(output.path, followLinks: false) !=
          FileSystemEntityType.notFound ||
      await FileSystemEntity.type(contentOutput.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
    throw const FileSystemException(
      'Outputs already exist; choose a fresh staging destination.',
    );
  }
  final root = Directory(await buildRoot.resolveSymbolicLinks());
  final destination = contentOutput.absolute;
  if (destination.path == root.path ||
      destination.path.startsWith('${root.path}${Platform.pathSeparator}')) {
    throw const FileSystemException(
      'Content output must be outside the source build.',
    );
  }
  final sources = <String, File>{};
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    final relative = entity.absolute.path
        .substring(root.path.length + 1)
        .replaceAll(Platform.pathSeparator, '/');
    if (relative.split('/').any((part) => part.startsWith('.'))) continue;
    if (entity is Link) {
      throw const FileSystemException('Build symlinks are not portable.');
    }
    if (entity is! File) continue;
    VrlzWebGameManifest.validatePath(relative);
    if (sources.length >= VrlzWebGameManifest.maxFiles) {
      throw const FormatException('Build exceeds file count.');
    }
    sources[relative] = entity;
  }
  if (!sources.containsKey(entrypoint)) {
    throw const FormatException('Entrypoint is missing from build.');
  }
  await destination.parent.create(recursive: true);
  final temporary = await destination.parent.createTemp('.webgame-pack-');
  final staged = Directory.fromUri(temporary.uri.resolve('content/'));
  await staged.create();
  var contentPublished = false, indexPublished = false;
  try {
    final metadata = <String, Map<String, Object?>>{};
    var total = 0;
    final paths = sources.keys.toList()..sort();
    for (final path in paths) {
      final source = sources[path]!,
          file = File.fromUri(staged.uri.resolve(path));
      if (await FileSystemEntity.type(source.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const FileSystemException('Build changed while being packaged.');
      }
      final size = await source.length();
      if (size > VrlzWebGameManifest.maxFileBytes ||
          size > VrlzWebGameManifest.maxTotalBytes - total) {
        throw const FormatException('Build exceeds resource byte budget.');
      }
      await file.parent.create(recursive: true);
      if (path == entrypoint) {
        var html = await source.readAsString();
        final base = RegExp(
          r'''<base\s+href\s*=\s*["'][^"']*["']\s*/?>''',
          caseSensitive: false,
        );
        html = base.hasMatch(html)
            ? html.replaceFirst(base, '<base href="./">')
            : html.replaceFirst(
                RegExp('<head[^>]*>', caseSensitive: false),
                '<head><base href="./">',
              );
        if (RegExp(
          r'https?://(?:www\.)?gstatic\.com/flutter-canvaskit',
          caseSensitive: false,
        ).hasMatch(html)) {
          throw const FormatException(
            'CanvasKit CDN is not portable: build with --no-web-resources-cdn.',
          );
        }
        await file.writeAsString(html, flush: true);
      } else {
        // APFS clone keeps large immutable build outputs independent without
        // allocating a second copy. Other filesystems retain the portable path.
        var cloned = false;
        if (Platform.isMacOS) {
          try {
            final result = await Process.run('/bin/cp', [
              '-c',
              source.path,
              file.path,
            ]);
            cloned = result.exitCode == 0;
          } catch (_) {}
        }
        if (!cloned) await source.copy(file.path);
      }
      final actual = await file.length();
      total += actual;
      if (actual > VrlzWebGameManifest.maxFileBytes ||
          total > VrlzWebGameManifest.maxTotalBytes) {
        throw const FormatException(
          'Staged build exceeds resource byte budget.',
        );
      }
      metadata[path] = {
        'path': path,
        'byteLength': actual,
        'sha256': '${await crypto.sha256.bind(file.openRead()).first}',
        'mediaType': _mime(path),
      };
    }
    final List<Object?> units;
    if (unitsJson == null) {
      bool bootstrap(String path) =>
          path == entrypoint ||
          (!path.contains('/') &&
              (path.endsWith('.js') ||
                  path.endsWith('.mjs') ||
                  path.endsWith('.wasm') ||
                  path.endsWith('.css')));
      final startup = paths.where(bootstrap).toList(),
          resources = paths.where((path) => !bootstrap(path)).toList();
      units = [
        {
          'id': 'startup',
          'startup': true,
          'files': [for (final path in startup) metadata[path]],
        },
        if (resources.isNotEmpty)
          {
            'id': 'resources',
            'startup': false,
            'files': [for (final path in resources) metadata[path]],
          },
      ];
    } else {
      if (unitsJson is! List) {
        throw const FormatException(
          'Units JSON must be a list of {id,startup,paths}.',
        );
      }
      final assigned = <String>{};
      units = [];
      for (final raw in unitsJson) {
        if (raw is! Map<String, dynamic> ||
            raw.keys.any(
              (key) => !const {'id', 'startup', 'paths'}.contains(key),
            ) ||
            raw['paths'] is! List) {
          throw const FormatException('Invalid authored unit map.');
        }
        final selected = <Map<String, Object?>>[];
        for (final path in raw['paths'] as List) {
          if (path is! String ||
              !metadata.containsKey(path) ||
              !assigned.add(path)) {
            throw const FormatException(
              'Unknown or duplicate authored file membership.',
            );
          }
          selected.add(metadata[path]!);
        }
        units.add({
          'id': raw['id'],
          'startup': raw['startup'],
          'files': selected,
        });
      }
      if (assigned.length != metadata.length) {
        throw const FormatException(
          'Authored units must cover all files exactly once.',
        );
      }
    }
    final manifest = VrlzWebGameManifest.fromJson({
      'formatVersion': 1,
      'runtime': VrlzWebGameManifest.runtime,
      'capabilities': ['web.sandbox'],
      'id': id,
      'title': title,
      'description': description,
      'revision': revision,
      'entrypoint': entrypoint,
      'contentBaseUrl': contentBaseUrl,
      'controllerProfile': controllerProfile,
      'controls': controlsJson ?? <String, String>{},
      'license': license,
      'assetNotice': assetNotice,
      'sourceUrl': sourceUrl,
      'licenseUrl': licenseUrl,
      'sourceArchiveUrl': sourceArchiveUrl,
      'networkOrigins': networkOriginsJson ?? <String>[],
      if (requirementsJson != null) 'requirements': requirementsJson,
      'viewportWidth': viewportWidth,
      'viewportHeight': viewportHeight,
      'units': units,
    });
    final index = VrlzPackage.encodeWebGame(manifest: manifest);
    final indexFile = File.fromUri(temporary.uri.resolve('index.vrlz'));
    await indexFile.writeAsBytes(index, flush: true);
    await output.parent.create(recursive: true);
    await output.create(exclusive: true);
    try {
      if (await FileSystemEntity.type(destination.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const FileSystemException(
          'Content output appeared during packaging.',
        );
      }
      await staged.rename(destination.path);
      contentPublished = true;
      await indexFile.rename(output.path);
      indexPublished = true;
    } finally {
      if (!indexPublished &&
          await FileSystemEntity.type(output.path, followLinks: false) ==
              FileSystemEntityType.file &&
          await output.length() == 0) {
        await output.delete();
      }
    }
    return manifest;
  } finally {
    if (contentPublished && !indexPublished) {
      await destination.delete(recursive: true);
    }
    await temporary.delete(recursive: true);
  }
}

String _mime(String path) {
  final lower = path.toLowerCase();
  final ext = lower.substring(lower.lastIndexOf('.') + 1);
  return const {
        'html': 'text/html',
        'js': 'application/javascript',
        'mjs': 'application/javascript',
        'css': 'text/css',
        'json': 'application/json',
        'wasm': 'application/wasm',
        'txt': 'text/plain',
        'png': 'image/png',
        'jpg': 'image/jpeg',
        'jpeg': 'image/jpeg',
        'webp': 'image/webp',
        'gif': 'image/gif',
        'svg': 'image/svg+xml',
        'avif': 'image/avif',
        'woff': 'font/woff',
        'woff2': 'font/woff2',
        'ttf': 'font/ttf',
        'otf': 'font/otf',
        'ogg': 'audio/ogg',
        'oga': 'audio/ogg',
        'mp3': 'audio/mpeg',
        'wav': 'audio/wav',
        'm4a': 'audio/mp4',
        'mp4': 'video/mp4',
        'webm': 'video/webm',
      }[ext] ??
      'application/octet-stream';
}
