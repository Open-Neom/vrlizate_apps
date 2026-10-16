import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'vrlz_nes_manifest.dart';
import 'vrz_glb.dart' show decodeVrzJson;
import 'vrz_zip.dart';

/// A validated iNES cartridge, not a downloaded native core or Flutter module.
///
/// The host must explicitly support [VrlzNesManifest.supportedRuntime]. Cartridge
/// instructions run inside its emulator, without direct host APIs. Format checks
/// do not certify the emulator's security or turn 2D content into stereoscopic 3D.
final class VrlzNesBundle {
  VrlzNesBundle._(this.manifest, Uint8List rom, this.source)
    : _rom = Uint8List.fromList(rom);

  static const maxRomBytes = 16 + 512 + 4 * 1024 * 1024;
  static const maxBytes = maxRomBytes + 64 * 1024;
  static const defaultRawRomLicense =
      'Cartucho NES cargado localmente por el usuario para reproducción personal '
      'en el emulador integrado de VRlizate.';
  static const defaultRawRomSourceUrl = 'https://vrlizate.org/local-nes-rom';

  final VrlzNesManifest manifest;
  final Uri? source;
  final Uint8List _rom;
  Uint8List get romBytes => Uint8List.fromList(_rom);

  bool get isNes2 => (_rom[7] & 0x0c) == 0x08;

  int get mapperNumber {
    final base = (_rom[6] >> 4) | (_rom[7] & 0xf0);
    return isNes2 ? (base | ((_rom[8] & 0x0f) << 8)) : base;
  }

  String get mapperName => switch (mapperNumber) {
    0 => 'NROM',
    1 => 'MMC1 (SxROM)',
    2 => 'UNROM (UxROM)',
    3 => 'CNROM',
    4 => 'MMC3 (TxROM)',
    5 => 'MMC5 (ExROM)',
    7 => 'AxROM',
    9 => 'MMC2 (PxROM)',
    10 => 'MMC4 (FxROM)',
    11 => 'Color Dreams',
    16 => 'Bandai FCG',
    18 => 'Jaleco SS88006',
    19 => 'Namco 163',
    21 || 23 || 25 => 'Konami VRC4',
    22 => 'Konami VRC2',
    24 || 26 => 'Konami VRC6',
    34 => 'BNROM / NINA-001',
    66 => 'GxROM',
    69 => 'Sunsoft FME-7',
    71 => 'Camerica',
    85 => 'Konami VRC7',
    _ => 'Mapper $mapperNumber',
  };

  int get prgBanks =>
      isNes2 ? (_rom[4] | ((_rom[9] & 0x0f) << 8)) : _rom[4];

  int get chrBanks =>
      isNes2 ? (_rom[5] | ((_rom[9] >> 4) << 8)) : _rom[5];

  int get prgKiB => prgBanks * 16;
  int get chrKiB => chrBanks * 8;
  bool get hasChrRam => chrBanks == 0;
  bool get hasBatteryRam => (_rom[6] & 0x02) != 0;
  bool get hasTrainer => (_rom[6] & 0x04) != 0;

  String get hardwareSummary {
    final chrLabel = hasChrRam ? 'CHR-RAM' : '$chrKiB KB CHR';
    final sramLabel = hasBatteryRam ? ' · SRAM' : '';
    return '$mapperName · $prgKiB KB PRG · $chrLabel$sramLabel';
  }

  /// Creates a validated [VrlzNesBundle] directly from a raw `.nes` cartridge file.
  static VrlzNesBundle fromRawRom(
    Uint8List romBytes, {
    required String fileName,
    Uri? source,
  }) {
    final owned = Uint8List.fromList(romBytes);
    _validateRom(owned);
    final hash = sha256.convert(owned).toString();
    final stem = _cleanStem(fileName);
    final slug = _slugify(stem, hash);
    final title = _humanizeTitle(stem);
    final tempBundle = VrlzNesBundle._(
      VrlzNesManifest.fromJson({
        'formatVersion': VrlzNesManifest.supportedFormatVersion,
        'id': 'rom.nes.$slug',
        'title': title,
        'description': '',
        'runtime': VrlzNesManifest.supportedRuntime,
        'entrypoint': 'game.nes',
        'capabilities': [VrlzNesManifest.supportedCapability],
        'sha256': {'game.nes': hash},
        'license': defaultRawRomLicense,
        'sourceUrl': defaultRawRomSourceUrl,
      }),
      owned,
      source,
    );
    final manifest = VrlzNesManifest.fromJson({
      'formatVersion': VrlzNesManifest.supportedFormatVersion,
      'id': 'rom.nes.$slug',
      'title': title,
      'description': 'Cartucho NES · ${tempBundle.hardwareSummary}',
      'runtime': VrlzNesManifest.supportedRuntime,
      'entrypoint': 'game.nes',
      'capabilities': [VrlzNesManifest.supportedCapability],
      'sha256': {'game.nes': hash},
      'license': defaultRawRomLicense,
      'sourceUrl': defaultRawRomSourceUrl,
    });
    return VrlzNesBundle._(manifest, owned, source);
  }

  static String _cleanStem(String fileName) {
    final segment = fileName.split(RegExp(r'[/\\]')).last.trim();
    final lower = segment.toLowerCase();
    final stem = lower.endsWith('.nes')
        ? segment.substring(0, segment.length - 4)
        : segment;
    return stem.trim().isEmpty ? 'Cartucho NES' : stem.trim();
  }

  static String _slugify(String stem, String hash) {
    final cleaned = stem
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final base = cleaned.isEmpty ? 'cartridge' : cleaned;
    final prefix = base.length > 40 ? base.substring(0, 40) : base;
    return '$prefix-${hash.substring(0, 8)}';
  }

  static String _humanizeTitle(String stem) {
    final words = stem
        .replaceAll(RegExp(r'[_-]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (words.isEmpty) return 'Cartucho NES';
    final titled = words
        .split(' ')
        .map(
          (w) => w.isEmpty
              ? w
              : '${w[0].toUpperCase()}${w.length > 1 ? w.substring(1) : ''}',
        )
        .join(' ');
    return titled.length <= 80 ? titled : titled.substring(0, 80);
  }

  static VrlzNesBundle decode(Uint8List bytes, {Uri? source}) {
    final files = readVrzZip(
      bytes,
      maxBytes,
      allowedFiles: const {'manifest.json', 'game.nes'},
    );
    final manifest = VrlzNesManifest.fromJson(
      decodeVrzJson(files['manifest.json']!),
    );
    final rom = files['game.nes']!;
    if (sha256.convert(rom).toString() != manifest.romSha256) {
      throw const FormatException(
        'game.nes does not match the manifest SHA-256.',
      );
    }
    _validateRom(rom);
    return VrlzNesBundle._(manifest, rom, source);
  }

  /// Packages the original licensed cartridge with deterministic STORE entries.
  static Uint8List encode({
    required Uint8List romBytes,
    required String id,
    required String title,
    String description = '',
    required String license,
    required String sourceUrl,
  }) {
    _validateRom(romBytes);
    final manifest = VrlzNesManifest.fromJson({
      'formatVersion': VrlzNesManifest.supportedFormatVersion,
      'id': id,
      'title': title,
      'description': description,
      'runtime': VrlzNesManifest.supportedRuntime,
      'entrypoint': 'game.nes',
      'capabilities': [VrlzNesManifest.supportedCapability],
      'sha256': {'game.nes': sha256.convert(romBytes).toString()},
      'license': license,
      'sourceUrl': sourceUrl,
    });
    final metadata = utf8.encode(jsonEncode(manifest.toJson()));
    final archive = Archive()
      ..add(ArchiveFile.noCompress('manifest.json', metadata.length, metadata))
      ..add(ArchiveFile.noCompress('game.nes', romBytes.length, romBytes));
    final encoded = ZipEncoder().encodeBytes(
      archive,
      modified: DateTime.utc(2000),
    );
    decode(encoded);
    return encoded;
  }

  static void _validateRom(Uint8List rom) {
    if (rom.length < 16 ||
        rom.length > maxRomBytes ||
        rom[0] != 0x4e ||
        rom[1] != 0x45 ||
        rom[2] != 0x53 ||
        rom[3] != 0x1a) {
      throw const FormatException(
        'NES VRLZ requires a bounded iNES cartridge.',
      );
    }
    if ((rom[7] & 0x03) != 0) {
      throw const FormatException(
        'Unsupported NES console type: VS-Unisystem and PlayChoice-10 are not supported.',
      );
    }
    final nes2 = (rom[7] & 0x0c) == 0x08;
    if (nes2 && ((rom[9] & 0x0f) == 0x0f || (rom[9] >> 4) == 0x0f)) {
      throw const FormatException(
        'Unsupported NES 2.0 exponent-multiplier ROM size.',
      );
    }
    final prgBanks = nes2 ? (rom[4] | ((rom[9] & 0x0f) << 8)) : rom[4];
    final chrBanks = nes2 ? (rom[5] | ((rom[9] >> 4) << 8)) : rom[5];
    final trainerBytes = (rom[6] & 0x04) != 0 ? 512 : 0;
    final expectedLength = 16 + trainerBytes + prgBanks * 16384 + chrBanks * 8192;
    if (prgBanks == 0 ||
        expectedLength > maxRomBytes ||
        rom.length != expectedLength) {
      throw const FormatException(
        'Unsupported NES profile: ROM size must match header PRG/CHR bank counts within 4 MiB.',
      );
    }
  }
}
