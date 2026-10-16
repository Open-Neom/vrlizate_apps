/// Bounded, immutable tile data interpreted by a host-owned 2.5D runtime.
/// Rows run top to bottom. A tile's centre X is column + 0.5; a character's
/// standing feet Y is height - 1 - row. No scripts or external assets are read.
final class VrlzRetroLevel {
  VrlzRetroLevel._(this.name, this.theme, this.mode, List<String> rows)
    : rows = List<String>.unmodifiable(rows);

  final String name, theme, mode;
  final List<String> rows;
  int get width => rows.first.length;
  int get height => rows.length;

  factory VrlzRetroLevel.fromJson(Map<String, Object?> json) {
    const fields = {'name', 'theme', 'mode', 'rows'};
    if (json.keys.any((key) => !fields.contains(key))) {
      throw const FormatException('Unknown retro level field.');
    }
    final name = json['name'];
    final theme = json['theme'];
    final mode = json['mode'];
    final rawRows = json['rows'];
    if (name is! String ||
        name.trim().isEmpty ||
        name.length > 80 ||
        (theme != 'garden' && theme != 'neon') ||
        (mode != 'platformer' && mode != 'blaster') ||
        rawRows is! List ||
        rawRows.length < 8 ||
        rawRows.length > 24 ||
        rawRows.any((row) => row is! String)) {
      throw const FormatException(
        'Invalid retro level name, theme, mode or rows.',
      );
    }
    final rows = rawRows.cast<String>();
    final width = rows.first.length;
    if (width < 16 ||
        width > 128 ||
        rows.any(
          (row) =>
              row.length != width ||
              RegExp(r'^[.#^*SGEBK]+$').stringMatch(row) != row,
        )) {
      throw const FormatException(
        'Retro levels need rectangular 16–128 by 8–24 ASCII tiles.',
      );
    }
    final counts = <String, int>{};
    for (final row in rows) {
      for (final symbol in row.split('')) {
        counts[symbol] = (counts[symbol] ?? 0) + 1;
      }
    }
    if (counts['S'] != 1 ||
        counts['G'] != 1 ||
        (counts['E'] ?? 0) > 32 ||
        (counts['B'] ?? 0) > 1 ||
        (counts['*'] ?? 0) > 128 ||
        (counts['K'] ?? 0) > 8) {
      throw const FormatException(
        'Retro level entity counts exceed the supported profile.',
      );
    }
    for (var y = 0; y < rows.length; y++) {
      for (var x = 0; x < width; x++) {
        if (rows[y][x] != 'S' && rows[y][x] != 'G') continue;
        if (x == 0 ||
            x == width - 1 ||
            y == 0 ||
            y == rows.length - 1 ||
            rows[y + 1][x] != '#' ||
            !'.*'.contains(rows[y - 1][x])) {
          throw const FormatException(
            'Spawn and exit require interior positions, solid footing and headroom.',
          );
        }
      }
    }
    return VrlzRetroLevel._(name, theme as String, mode as String, rows);
  }

  Map<String, Object?> toJson() => {
    'name': name,
    'theme': theme,
    'mode': mode,
    'rows': rows,
  };
}
