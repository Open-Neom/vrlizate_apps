import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show Deflate, getCrc32;
import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_apps/vrlizate_apps.dart';
import 'package:vrlizate_world/vrlizate_world.dart' show VrlwBundleCodec;

import 'support/vrlz_world_fixture.dart';
import 'support/vrz_fixture.dart';

typedef _OpenNative =
    ffi.Int32 Function(ffi.Pointer<ffi.Char> path, ffi.Int32 flags);
typedef _OpenDart = int Function(ffi.Pointer<ffi.Char> path, int flags);

typedef _LseekNative =
    ffi.Int64 Function(ffi.Int32 fd, ffi.Int64 offset, ffi.Int32 whence);
typedef _LseekDart = int Function(int fd, int offset, int whence);

typedef _CloseNative = ffi.Int32 Function(ffi.Int32 fd);
typedef _CloseDart = int Function(int fd);

typedef _MallocNative = ffi.Pointer<ffi.Uint8> Function(ffi.Size size);
typedef _MallocDart = ffi.Pointer<ffi.Uint8> Function(int size);

typedef _FreeNative = ffi.Void Function(ffi.Pointer<ffi.Void> ptr);
typedef _FreeDart = void Function(ffi.Pointer<ffi.Void> ptr);

final class _SpyRandomAccessSource implements VrlzRandomAccessSource {
  _SpyRandomAccessSource(this._bytes, {this.readDelay = Duration.zero});

  final Uint8List _bytes;
  final Duration readDelay;
  bool _closed = false;
  int readCallCount = 0;
  final List<(int offset, int length)> readSpans = <(int, int)>[];

  @override
  int get length => _bytes.length;

  @override
  String get displayName => 'spy.vrlz';

  @override
  bool get isClosed => _closed;

  @override
  Future<Uint8List> readRange(int offset, int length) async {
    if (_closed) throw StateError('Spy source closed.');
    readCallCount++;
    readSpans.add((offset, length));
    if (readDelay > Duration.zero) {
      await Future<void>.delayed(readDelay);
    }
    return Uint8List.fromList(
      Uint8List.sublistView(_bytes, offset, offset + length),
    );
  }

  bool readAnyByteInside(int start, int endExclusive) {
    for (final (off, len) in readSpans) {
      final rEnd = off + len;
      if (off < endExclusive && rEnd > start) return true;
    }
    return false;
  }

  @override
  Future<void> close() async {
    _closed = true;
  }
}

Uint8List _buildMixedStoreAndDeflateZip(
  Map<String, ({Uint8List bytes, bool deflate})> entries,
) {
  final local = BytesBuilder(copy: false);
  final central = BytesBuilder(copy: false);

  for (final e in entries.entries) {
    final nameBytes = utf8.encode(e.key);
    final raw = e.value.bytes;
    final method = e.value.deflate ? 8 : 0;
    final packed = e.value.deflate
        ? Uint8List.fromList(Deflate(raw).getBytes())
        : raw;
    final crc = getCrc32(raw);
    final offset = local.length;

    final lh = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 0x0800, Endian.little)
      ..setUint16(8, method, Endian.little)
      ..setUint16(12, 0x2821, Endian.little)
      ..setUint32(14, crc, Endian.little)
      ..setUint32(18, packed.length, Endian.little)
      ..setUint32(22, raw.length, Endian.little)
      ..setUint16(26, nameBytes.length, Endian.little);
    local
      ..add(lh.buffer.asUint8List())
      ..add(nameBytes)
      ..add(packed);

    final cd = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 20, Endian.little)
      ..setUint16(8, 0x0800, Endian.little)
      ..setUint16(10, method, Endian.little)
      ..setUint16(14, 0x2821, Endian.little)
      ..setUint32(16, crc, Endian.little)
      ..setUint32(20, packed.length, Endian.little)
      ..setUint32(24, raw.length, Endian.little)
      ..setUint16(28, nameBytes.length, Endian.little)
      ..setUint32(42, offset, Endian.little);
    central
      ..add(cd.buffer.asUint8List())
      ..add(nameBytes);
  }

  final end = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, entries.length, Endian.little)
    ..setUint16(10, entries.length, Endian.little)
    ..setUint32(12, central.length, Endian.little)
    ..setUint32(16, local.length, Endian.little);

  return (BytesBuilder(copy: false)
        ..add(local.takeBytes())
        ..add(central.takeBytes())
        ..add(end.buffer.asUint8List()))
      .takeBytes();
}

void main() {
  group('VrlzFdSpec', () {
    test('parses valid fd:<n> and fd:<n>/<name> and sanitizes paths', () {
      final a = VrlzFdSpec.parse('fd:42/expedition.vrlz');
      expect(a.fd, 42);
      expect(a.displayName, 'expedition.vrlz');
      expect(a.canonicalSpec, 'fd:42/expedition.vrlz');

      final b = VrlzFdSpec.parse('fd:7');
      expect(b.fd, 7);
      expect(b.displayName, 'archive.vrlz');

      final traversal = VrlzFdSpec.parse('fd:19/../../Downloads/world_pack.vrlz');
      expect(traversal.fd, 19);
      expect(traversal.displayName, 'world_pack.vrlz');
    });

    test('rejects malformed or negative descriptor specs', () {
      for (final bad in [
        '',
        'file:///tmp/a.vrlz',
        'fd:',
        'fd:-3/a.vrlz',
        'fd:abc/a.vrlz',
        'fd:99999999999/a.vrlz',
        'fd:12/..',
      ]) {
        expect(VrlzFdSpec.tryParse(bad), isNull, reason: bad);
        expect(() => VrlzFdSpec.parse(bad), throwsFormatException, reason: bad);
      }
    });
  });

  group('POSIX F_DUPFD_CLOEXEC + pread & unlinked mmap temp buffer', () {
    test(
      'openFdSpec duplicates descriptor cleanly and leaves caller fd open',
      () async {
        if (!Platform.isMacOS && !Platform.isLinux && !Platform.isAndroid) {
          return;
        }
        final libc = ffi.DynamicLibrary.process();
        final posixOpen = libc.lookupFunction<_OpenNative, _OpenDart>('open');
        final posixLseek = libc.lookupFunction<_LseekNative, _LseekDart>(
          'lseek',
        );
        final posixClose = libc.lookupFunction<_CloseNative, _CloseDart>(
          'close',
        );
        final malloc = libc.lookupFunction<_MallocNative, _MallocDart>(
          'malloc',
        );
        final free = libc.lookupFunction<_FreeNative, _FreeDart>('free');

        final tmpDir = await Directory.systemTemp.createTemp('vrlz_fd_test_');
        final file = File('${tmpDir.path}/sample_pack.vrlz');
        final payload = fixtureWorlds();
        await file.writeAsBytes(payload, flush: true);

        final pathBytes = utf8.encode(file.path);
        final cPath = malloc(pathBytes.length + 1);
        for (var i = 0; i < pathBytes.length; i++) {
          cPath[i] = pathBytes[i];
        }
        cPath[pathBytes.length] = 0;
        final rawFd = posixOpen(cPath.cast<ffi.Char>(), 0 /* O_RDONLY */);
        free(cPath.cast<ffi.Void>());
        expect(rawFd, greaterThanOrEqualTo(0));

        try {
          final source = await VrlzRandomAccessSource.openFdSpec(
            'fd:$rawFd/sample_pack.vrlz',
          );
          expect(source.length, payload.length);
          expect(source.displayName, 'sample_pack.vrlz');

          // Concurrent out-of-order pread slices must match exact offsets.
          final slices = await Future.wait([
            source.readRange(0, 32),
            source.readRange(payload.length - 22, 22),
            source.readRange(64, 48),
          ]);
          expect(slices[0], payload.sublist(0, 32));
          expect(slices[1], payload.sublist(payload.length - 22));
          expect(slices[2], payload.sublist(64, 112));

          await source.close();
          expect(source.isClosed, isTrue);

          // Caller's original rawFd MUST remain open because openFdSpec uses
          // F_DUPFD_CLOEXEC rather than stealing ownership of rawFd.
          final pos = posixLseek(rawFd, 0, 1 /* SEEK_CUR */);
          expect(pos, greaterThanOrEqualTo(0));
        } finally {
          posixClose(rawFd);
          await tmpDir.delete(recursive: true);
        }
      },
    );

    test(
      'VrlzTempBufferSink unlinks immediately and mmaps read-only pages',
      () async {
        int countLeakedTempFiles() => Directory.systemTemp
            .listSync()
            .where((e) => e.path.contains('vrlz_tmp_'))
            .length;

        final beforeCount = countLeakedTempFiles();
        final data = Uint8List.fromList(
          List<int>.generate(96 * 1024, (i) => (i * 37 + 11) & 0xff),
        );

        final sink = VrlzTempBufferSink.open(expectedLength: data.length);
        sink.addSlice(data, 0, 40 * 1024);
        sink.addSlice(data, 40 * 1024, data.length);
        final tempBuf = sink.finish();

        try {
          // Unlinked on creation: zero visible temp files even while open!
          expect(countLeakedTempFiles(), beforeCount);
          if (Platform.isMacOS || Platform.isLinux || Platform.isAndroid) {
            expect(tempBuf.isFileBacked, isTrue);
            expect(tempBuf.isMemoryMapped, isTrue);
          }
          expect(tempBuf.length, data.length);
          expect(
            await tempBuf.readRange(1234, 4096),
            data.sublist(1234, 1234 + 4096),
          );
        } finally {
          await tempBuf.close();
          expect(tempBuf.isClosed, isTrue);
          expect(countLeakedTempFiles(), beforeCount);
        }
      },
    );
  });

  group('VrlzStreamArchive & zero-unpack VrlzWorldBundle.openStream', () {
    test(
      'coalesces concurrent reads, enforces LRU budget, and spills DEFLATE to mmap',
      () async {
        final manifestBytes = Uint8List.fromList(
          utf8.encode(jsonEncode({'id': 'demo'})),
        );
        final smallA = Uint8List.fromList(List<int>.filled(2048, 0x41));
        final smallB = Uint8List.fromList(List<int>.filled(2048, 0x42));
        final largeDeflated = Uint8List.fromList(
          List<int>.generate(130 * 1024, (i) => (i * 7) & 0xff),
        );

        final archiveBytes = _buildMixedStoreAndDeflateZip({
          'manifest.json': (bytes: manifestBytes, deflate: false),
          'small_a.bin': (bytes: smallA, deflate: false),
          'small_b.bin': (bytes: smallB, deflate: true),
          'large_deflate.bin': (bytes: largeDeflated, deflate: true),
        });

        final spy = _SpyRandomAccessSource(
          archiveBytes,
          readDelay: const Duration(milliseconds: 8),
        );

        final archive = await VrlzStreamArchive.open(
          spy,
          allowAdditionalFile: (_) => true,
          maxMemoryCacheBytes: 3000, // Holds only ONE 2048-byte small entry!
          tempFileThresholdBytes: 64 * 1024, // 130 KiB spills to mmap temp!
        );

        try {
          final readsAfterOpen = spy.readCallCount;

          // Concurrent reads of small_a.bin must coalesce into one read path.
          final concurrent = await Future.wait([
            archive.readEntryBytes('small_a.bin'),
            archive.readEntryBytes('small_a.bin'),
            archive.readEntryBytes('small_a.bin'),
          ]);
          for (final res in concurrent) {
            expect(res, smallA);
          }
          final readsAfterSmallA = spy.readCallCount;
          // Local header (30 + filename) + payload = 3 reads total, not 9!
          expect(readsAfterSmallA - readsAfterOpen, lessThanOrEqualTo(3));
          expect(archive.cachedMemoryBytes, 2048);

          // Reading small_b.bin (2048 B) exceeds 3000 B LRU cap -> evicts small_a.bin!
          expect(await archive.readEntryBytes('small_b.bin'), smallB);
          expect(archive.cachedMemoryBytes, 2048);

          // Large DEFLATE entry (>= 64 KiB) inflates via sliding window into mmap buffer.
          final byteSource = await archive.openEntryByteSource(
            'large_deflate.bin',
          );
          expect(archive.spilledEntryCount, 1);
          expect(byteSource.length, largeDeflated.length);
          expect(
            await byteSource.readRange(10000, 8192),
            largeDeflated.sublist(10000, 18192),
          );
          expect(await archive.readEntryBytes('large_deflate.bin'), largeDeflated);
        } finally {
          await archive.close();
          expect(spy.isClosed, isTrue);
        }
      },
    );

    test('rejects corrupted CRC-32 payload on read', () async {
      final raw = Uint8List.fromList(utf8.encode('authentic-payload-bytes'));
      final zip = Uint8List.fromList(
        _buildMixedStoreAndDeflateZip({
          'manifest.json': (
            bytes: Uint8List.fromList(utf8.encode('{}')),
            deflate: false,
          ),
          'asset.bin': (bytes: raw, deflate: false),
        }),
      );
      // Flip one byte inside `asset.bin` payload before the central directory.
      final assetHeaderIndex = zip.length - 22 - (46 + 13) - (46 + 9) - raw.length;
      zip[assetHeaderIndex + 2] ^= 0xff;

      final archive = await VrlzStreamArchive.open(
        VrlzRandomAccessSource.memory(zip),
        allowAdditionalFile: (_) => true,
      );
      await expectLater(
        archive.readEntryBytes('asset.bin'),
        throwsFormatException,
      );
      await archive.close();
    });

    test(
      'VrlzPackage.openStream opens multi-world v1 bundle without reading unvisited worlds',
      () async {
        final aliases = ['citadel', 'gallery', 'observatory', 'garden'];
        var lcg = 0x12345678;
        final bigRgba = Uint8List.fromList(
          List<int>.generate(256 * 128 * 4, (_) {
            lcg = (lcg * 1664525 + 1013904223) & 0xffffffff;
            return (lcg >> 16) & 0xff;
          }),
        );
        final fixture = worldFixture(
          worldAliases: aliases,
          changeWorld: (w) {
            final res = w['resources'] as List;
            res[1] = <String, Object>{
              'id': 'floor.color',
              'type': 'texture.rgba8',
              'width': 256,
              'height': 128,
              'data': base64Encode(bigRgba),
            };
          },
        );
        fixture.manifest['formatVersion'] = 1;
        fixture.manifest['runtime'] = VrlzWorldManifest.runtime;
        fixture.manifest['capabilities'] = const <String>[
          'worlds.local',
          'worlds.pbr',
        ];
        fixture.manifest['entrypoint'] = 'garden';
        fixture.manifest['portals'] = [
          for (var i = 0; i < aliases.length; i++)
            {
              'id': 'portal_$i',
              'from': aliases[i],
              'to': aliases[(i + 1) % aliases.length],
              'position': [3, 1.6, 2],
              'arrival': [4, 1.6, 4],
              'yaw': 0,
              'label': 'Next',
            },
        ];

        final vrlzBytes = VrlzWorldBundle.encode(
          fixture.manifest,
          fixture.files,
        );
        final spy = _SpyRandomAccessSource(vrlzBytes);

        // Locate binary resource payload span of unvisited `world_citadel.vrlw`:
        final citadelRaw = fixture.files['world_citadel.vrlw']!;
        final citadelVrlwPayloadOffset = VrlwBundleCodec.parseHeader(
          citadelRaw.sublist(0, 16),
        ).payloadOffset;
        final probe = await VrlzStreamArchive.open(
          VrlzRandomAccessSource.memory(vrlzBytes),
          allowAdditionalFile: (_) => true,
        );
        final citadelInfo = probe.entry('world_citadel.vrlw')!;
        final citadelEntryStart =
            citadelInfo.localHeaderOffset +
            30 +
            utf8.encode(citadelInfo.name).length;
        final citadelResourceStart =
            citadelEntryStart + citadelVrlwPayloadOffset;
        final citadelPayloadEnd = citadelEntryStart + citadelInfo.packedBytes;
        await probe.close();

        final pkg = await VrlzPackage.openStream(spy);
        try {
          expect(pkg.kind, VrlzPackageKind.worlds);
          final bundle = pkg.worldBundle!;
          expect(bundle.isStreaming, isTrue);
          expect(bundle.manifest.formatVersion, 1);
          expect(bundle.manifest.runtimeId, VrlzWorldManifest.runtime);
          expect(bundle.manifest.hasExtendedProfile, isTrue);
          expect(bundle.manifest.worlds, hasLength(4));

          // Open ONLY `garden`: `world_citadel.vrlw`'s 128 KiB resource payload is NEVER read!
          final prepared = await bundle.openWorld('garden');
          try {
            expect(prepared.reader.index.id, 'test.garden');
            expect(prepared.resources['floor.model'], triangleGlb());
          } finally {
            await prepared.reader.close();
          }

          expect(
            spy.readAnyByteInside(citadelResourceStart, citadelPayloadEnd),
            isFalse,
            reason:
                'Streaming .vrlz v1 must only read world headers/indices on boot '
                'and never pull unvisited world payloads into RAM.',
          );
        } finally {
          await pkg.close();
        }
      },
    );
  });
}
