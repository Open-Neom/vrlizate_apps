import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:vrlizate_apps/vrlizate_apps.dart';
import 'package:vrlizate_apps/vrlizate_apps_io.dart';

const _usage =
    'Usage: dart --packages=.dart_tool/package_config.json '
    'tool/index_vrlz.dart DIRECTORY [--output PATH] [--force]\n'
    'Default output: DIRECTORY/catalog.json. Publish the index beside its packages.';

Future<void> main(List<String> arguments) async {
  if (arguments.contains('--help')) {
    stdout.writeln(_usage);
    return;
  }
  late final ({String directory, String? output, bool force}) options;
  try {
    options = _options(arguments);
  } on FormatException catch (error) {
    stderr.writeln('${error.message}\n$_usage');
    exitCode = 64;
    return;
  }
  try {
    final file = await writeVrlzIndex(
      options.directory,
      outputPath: options.output,
      force: options.force,
    );
    stdout.writeln('Validated VRLZ web catalog written to ${file.path}.');
  } on Object catch (error) {
    stderr.writeln('Cannot index VRLZ packages: $error');
    exitCode = 1;
  }
}

/// Generates a snapshot of a flat package directory; it never deploys files.
///
/// Relative URLs refer to filenames beside the eventual published index, even
/// when [outputPath] selects a different local staging directory.
Future<File> writeVrlzIndex(
  String directoryPath, {
  String? outputPath,
  bool force = false,
}) async {
  final store = VrlzDirectoryStore(directoryPath);
  final snapshot = await store.scan();
  if (!snapshot.isComplete || snapshot.issues.isNotEmpty) {
    final reasons = snapshot.issues
        .map(
          (issue) =>
              '${issue.fileName.isEmpty ? snapshot.rootPath : issue.fileName}: ${issue.message}',
        )
        .join('\n');
    throw StateError(
      'The directory must be fully scanned without issues; no index was written.'
      '${reasons.isEmpty ? '' : '\n$reasons'}',
    );
  }
  final packages = [
    for (final entry in snapshot.entries)
      {
        'id': entry.metadata.id,
        'title': entry.metadata.title,
        'url': Uri.encodeComponent(entry.fileName),
        'sha256': entry.fingerprint,
      },
  ];
  final bytes = Uint8List.fromList(
    utf8.encode(
      '${const JsonEncoder.withIndent('  ').convert({'formatVersion': 1, 'packages': packages})}\n',
    ),
  );
  // Reuse the receiving contract for schema, URL, duplicate and size checks.
  VrlzWebCatalog.decode(
    bytes,
    source: Uri.parse('https://vrlz-index.invalid/catalog.json'),
  );
  final output = outputPath == null
      ? File.fromUri(Directory(snapshot.rootPath).uri.resolve('catalog.json'))
      : File(outputPath).absolute;
  if (output.path.toLowerCase().endsWith('.vrlz')) {
    throw const FileSystemException(
      'The index output must not replace a .vrlz package.',
    );
  }
  final type = await FileSystemEntity.type(output.path, followLinks: false);
  if (type != FileSystemEntityType.notFound &&
      (type != FileSystemEntityType.file || !force)) {
    throw FileSystemException(
      type == FileSystemEntityType.file
          ? 'Output exists; use --force to replace the index.'
          : 'Output must be a regular file, never a link or directory.',
      output.path,
    );
  }
  await output.parent.create(recursive: true);
  final temporary = await output.parent.createTemp('.vrlz-index-');
  FileStat? reservation;
  var published = false;
  try {
    final staged = File.fromUri(temporary.uri.resolve('catalog.part'));
    await staged.writeAsBytes(bytes, flush: true);
    if (!force) {
      // Exclusive creation protects an output created after the initial check.
      await output.create(exclusive: true);
      reservation = await output.stat();
    } else {
      final current = await FileSystemEntity.type(
        output.path,
        followLinks: false,
      );
      if (current != FileSystemEntityType.file &&
          current != FileSystemEntityType.notFound) {
        throw FileSystemException(
          'Output changed into a link or directory.',
          output.path,
        );
      }
    }
    await staged.rename(output.path);
    published = true;
    return output;
  } finally {
    if (!published && reservation != null) {
      final currentType = await FileSystemEntity.type(
        output.path,
        followLinks: false,
      );
      if (currentType == FileSystemEntityType.file) {
        final current = await output.stat();
        if (current.size == 0 &&
            current.modified == reservation.modified &&
            current.changed == reservation.changed) {
          await output.delete();
        }
      }
    }
    await temporary.delete(recursive: true);
  }
}

({String directory, String? output, bool force}) _options(
  List<String> arguments,
) {
  String? directory;
  String? output;
  var force = false;
  for (var i = 0; i < arguments.length; i++) {
    final argument = arguments[i];
    if (argument == '--force') {
      if (force) throw const FormatException('Duplicate --force option.');
      force = true;
    } else if (argument == '--output') {
      if (output != null ||
          i + 1 >= arguments.length ||
          arguments[i + 1].startsWith('--') ||
          arguments[i + 1].trim().isEmpty) {
        throw const FormatException('Duplicate or incomplete --output option.');
      }
      output = arguments[++i];
    } else if (argument.startsWith('--') ||
        directory != null ||
        argument.trim().isEmpty) {
      throw const FormatException(
        'Provide one directory and known options only.',
      );
    } else {
      directory = argument;
    }
  }
  if (directory == null) {
    throw const FormatException('A package directory is required.');
  }
  return (directory: directory, output: output, force: force);
}
