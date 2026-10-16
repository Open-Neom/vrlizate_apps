import 'dart:typed_data';

import '../bundles/vrz_glb.dart' show decodeVrzJson;

/// An explicit web index, not an HTTP directory listing or executable manifest.
final class VrlzWebCatalog {
  VrlzWebCatalog._(this.source, List<VrlzWebCatalogEntry> entries)
    : entries = List.unmodifiable(entries);

  static const maxBytes = 256 * 1024;
  static const maxEntries = 128;
  final Uri source;
  final List<VrlzWebCatalogEntry> entries;

  static VrlzWebCatalog decode(Uint8List bytes, {required Uri source}) {
    _validateHttps(source);
    if (bytes.length > maxBytes) {
      throw const FormatException('VRLZ web catalog exceeds 256 KiB.');
    }
    final json = decodeVrzJson(bytes);
    if (json.length != 2 ||
        json['formatVersion'] is! int ||
        json['formatVersion'] != 1 ||
        json['packages'] is! List) {
      throw const FormatException('Unsupported VRLZ web catalog schema.');
    }
    final packages = json['packages'] as List;
    if (packages.length > maxEntries) {
      throw const FormatException('VRLZ web catalog exceeds 128 entries.');
    }
    final entries = <VrlzWebCatalogEntry>[];
    final ids = <String>{};
    final urls = <String>{};
    for (final value in packages) {
      if (value is! Map<String, Object?> ||
          value.length != 4 ||
          value.keys.any(
            (key) => !const {'id', 'title', 'url', 'sha256'}.contains(key),
          )) {
        throw const FormatException(
          'Unknown or missing web catalog entry field.',
        );
      }
      final id = value['id'];
      final title = value['title'];
      final address = value['url'];
      final hash = value['sha256'];
      if (id is! String ||
          id.length > 128 ||
          RegExp(r'^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)+$').stringMatch(id) !=
              id ||
          title is! String ||
          title.trim().isEmpty ||
          title.length > 80 ||
          address is! String ||
          address.trim().isEmpty ||
          address.length > 2048 ||
          hash is! String ||
          hash.length != 64 ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
        throw const FormatException('Invalid VRLZ web catalog entry.');
      }
      final url = source.resolve(address).normalizePath();
      _validateHttps(url);
      // origin canonicalizes the default HTTPS port; normalizePath removes
      // dot segments before detecting aliases of the same requested URL.
      final urlKey =
          '${url.origin}${url.path}${url.hasQuery ? '?${url.query}' : ''}';
      if (!ids.add(id) || !urls.add(urlKey)) {
        throw const FormatException('Duplicate VRLZ catalog id or URL.');
      }
      entries.add(VrlzWebCatalogEntry._(id, title, url, hash));
    }
    return VrlzWebCatalog._(source, entries);
  }
}

/// Index metadata is a hint; downloaded bytes must match [sha256] and [id].
final class VrlzWebCatalogEntry {
  const VrlzWebCatalogEntry._(this.id, this.title, this.url, this.sha256);

  final String id;
  final String title;
  final Uri url;
  final String sha256;
}

void _validateHttps(Uri uri) {
  if (uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      uri.port < 1 ||
      uri.port > 65535) {
    throw const FormatException(
      'VRLZ catalog URLs require HTTPS without credentials or fragments.',
    );
  }
}
