import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:vrlizate/vrlizate.dart' show VrDirectDeviceBridge;
import 'package:vrlizate_world/vrlizate_world.dart' show VrlwByteSource;

import '../../src/third_party/posix_stream_io.g.dart';
import 'vrlz_stream_source.dart';

Future<VrlzRandomAccessSource> openFileRandomAccessSource(String path) =>
    FileRandomAccessSource.open(path);

Future<VrlzRandomAccessSource> openFdSpecRandomAccessSource(String spec) =>
    PosixFdRandomAccessSource.openSpec(spec);

Future<VrlzRandomAccessSource> openPosixFdRandomAccessSource(
  int fd, {
  String displayName = 'archive.vrlz',
}) => PosixFdRandomAccessSource.openFd(fd, displayName: displayName);

Future<VrlzRandomAccessSource> openAndroidSafUriRandomAccessSource(
  String contentUri, {
  String displayName = 'archive.vrlz',
}) => PosixFdRandomAccessSource.openAndroidSafUri(
  contentUri,
  displayName: displayName,
);

VrlzTempBufferSink createTempBufferSink({required int expectedLength}) =>
    FileBackedTempBufferSink(expectedLength: expectedLength);

// ---------------------------------------------------------------------------
// POSIX FFI bindings generated via `package:ffigen` (`posix_stream_io.g.dart`)
// ---------------------------------------------------------------------------

final class _PosixBindings {
  _PosixBindings._(this._gen, {required this.use64Suffix});

  static final _PosixBindings? instance = _tryBind();

  static bool get isSupportedPlatform =>
      Platform.isAndroid ||
      Platform.isLinux ||
      Platform.isMacOS ||
      Platform.isIOS;

  static int get fDupFdCloexec =>
      (Platform.isMacOS || Platform.isIOS) ? 67 : 1030;

  static const int oRdonly = 0;
  static int get oCloexec =>
      (Platform.isMacOS || Platform.isIOS) ? 0x01000000 : 0x00080000;
  static const int seekEnd = 2;
  static const int protRead = 1;
  static const int mapPrivate = 2;

  final PosixStreamIoBindings _gen;
  final bool use64Suffix;

  static _PosixBindings? _tryBind() {
    if (!isSupportedPlatform) return null;
    try {
      final lib = ffi.DynamicLibrary.process();
      final gen = PosixStreamIoBindings(lib);
      var needs64 = false;
      if ((Platform.isAndroid || Platform.isLinux) &&
          ffi.sizeOf<ffi.IntPtr>() == 4) {
        try {
          lib.lookup<ffi.NativeType>('pread64');
          needs64 = true;
        } on Object {
          needs64 = false;
        }
      }
      // Eagerly resolve core leaf symbols once so missing symbols fail closed.
      final probe = gen.malloc(1);
      if (probe != ffi.nullptr) gen.free(probe);
      return _PosixBindings._(gen, use64Suffix: needs64);
    } on Object {
      return null;
    }
  }

  int close(int fd) => _gen.close(fd);

  int fcntlDup(int fd, int cmd, int minFd) => _gen.fcntlInt(fd, cmd, minFd);

  int lseek(int fd, int offset, int whence) =>
      use64Suffix ? _gen.lseek64(fd, offset, whence) : _gen.lseek(fd, offset, whence);

  int mmap(int addr, int len, int prot, int flags, int fd, int offset) {
    final addrPtr = ffi.Pointer<ffi.Void>.fromAddress(addr);
    final res = use64Suffix
        ? _gen.mmap64(addrPtr, len, prot, flags, fd, offset)
        : _gen.mmap(addrPtr, len, prot, flags, fd, offset);
    return res.address;
  }

  int munmap(int addr, int len) =>
      _gen.munmap(ffi.Pointer<ffi.Void>.fromAddress(addr), len);

  int openReadOnlyPath(String path) {
    final encoded = utf8.encode(path);
    final cStr = _gen.malloc(encoded.length + 1).cast<ffi.Uint8>();
    if (cStr == ffi.nullptr) {
      throw const FileSystemException('Out of native memory opening path.');
    }
    try {
      cStr.asTypedList(encoded.length).setAll(0, encoded);
      cStr[encoded.length] = 0;
      return _gen.open(cStr.cast<ffi.Char>(), oRdonly | oCloexec);
    } finally {
      _gen.free(cStr.cast());
    }
  }

  Uint8List preadExact(int fd, int offset, int length) {
    if (length == 0) return Uint8List(0);
    final scratch = _gen.malloc(length).cast<ffi.Uint8>();
    if (scratch == ffi.nullptr) {
      throw const FileSystemException('Out of native memory in pread.');
    }
    try {
      var done = 0;
      while (done < length) {
        final dst = ffi.Pointer<ffi.Void>.fromAddress(scratch.address + done);
        final got = use64Suffix
            ? _gen.pread64(fd, dst, length - done, offset + done)
            : _gen.pread(fd, dst, length - done, offset + done);
        if (got == 0) {
          throw const FormatException(
            'Unexpected EOF during VRLZ random-access pread.',
          );
        }
        if (got < 0) {
          throw FileSystemException(
            'POSIX pread failed on VRLZ descriptor (rc=$got).',
          );
        }
        done += got;
      }
      return Uint8List.fromList(scratch.asTypedList(length));
    } finally {
      _gen.free(scratch.cast());
    }
  }
}

// ---------------------------------------------------------------------------
// PosixFdRandomAccessSource (`fd:<n>/<name>` Android SAF / launcher bridge)
// ---------------------------------------------------------------------------

/// Random-access `.vrlz` reader over a duplicated POSIX file descriptor.
///
/// Duplicates the caller's descriptor via `fcntl(fd, F_DUPFD_CLOEXEC, 0)` so
/// [close] releases only our private descriptor and never invalidates an
/// Android SAF `ParcelFileDescriptor` owned by the Activity/caller.
final class PosixFdRandomAccessSource implements VrlzRandomAccessSource {
  PosixFdRandomAccessSource._({
    required int ownedFd,
    required this.length,
    required this.displayName,
    required _PosixBindings posix,
  }) : _fd = ownedFd,
       _posix = posix;

  int _fd;
  final _PosixBindings _posix;
  bool _closed = false;

  @override
  final int length;

  @override
  final String displayName;

  @override
  bool get isClosed => _closed;

  /// Opens a `content://` Android SAF URI directly via JNI (`detachFd`) and
  /// owns the resulting POSIX file descriptor without duplicating it.
  static Future<PosixFdRandomAccessSource> openAndroidSafUri(
    String contentUri, {
    String displayName = 'archive.vrlz',
  }) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError(
        'openAndroidSafUri requires Android Storage Access Framework.',
      );
    }
    final posix = _PosixBindings.instance;
    if (posix == null) {
      throw UnsupportedError('POSIX pread is unavailable on this runtime.');
    }
    final detachedFd = VrDirectDeviceBridge.instance
        .detachAndroidSafReadOnlyFdSync(contentUri);
    if (detachedFd == null || detachedFd < 0) {
      throw FileSystemException(
        'Failed to open Android SAF content URI via direct JNI.',
        contentUri,
      );
    }
    final size = posix.lseek(detachedFd, 0, _PosixBindings.seekEnd);
    if (size < 0) {
      posix.close(detachedFd);
      throw FileSystemException(
        'Android SAF content URI is unseekable (pipe/virtual stream).',
        contentUri,
      );
    }
    return PosixFdRandomAccessSource._(
      ownedFd: detachedFd,
      length: size,
      displayName: displayName,
      posix: posix,
    );
  }

  /// Duplicates [spec] (`"fd:<n>/<name>"`) with `F_DUPFD_CLOEXEC` and sizes it.
  static Future<PosixFdRandomAccessSource> openSpec(String spec) {
    final parsed = VrlzFdSpec.parse(spec);
    return openFd(parsed.fd, displayName: parsed.displayName);
  }

  /// Duplicates [fd] with `F_DUPFD_CLOEXEC` and determines byte length.
  static Future<PosixFdRandomAccessSource> openFd(
    int fd, {
    String displayName = 'archive.vrlz',
  }) async {
    if (fd < 0) {
      throw ArgumentError.value(fd, 'fd', 'File descriptor must be >= 0.');
    }
    final posix = _PosixBindings.instance;
    if (posix == null) {
      throw UnsupportedError(
        'PosixFdRandomAccessSource requires Android, Linux, macOS, or iOS.',
      );
    }
    final dupFd = posix.fcntlDup(fd, _PosixBindings.fDupFdCloexec, 0);
    if (dupFd < 0) {
      throw FileSystemException(
        'Failed to duplicate VRLZ file descriptor $fd with F_DUPFD_CLOEXEC.',
      );
    }
    final size = posix.lseek(dupFd, 0, _PosixBindings.seekEnd);
    if (size < 0) {
      posix.close(dupFd);
      throw FileSystemException(
        'Failed to seek size of VRLZ file descriptor $fd (unseekable pipe?).',
      );
    }
    return PosixFdRandomAccessSource._(
      ownedFd: dupFd,
      length: size,
      displayName: displayName,
      posix: posix,
    );
  }

  @override
  Future<Uint8List> readRange(int offset, int count) async {
    if (_closed || _fd < 0) {
      throw StateError('VRLZ fd source is closed.');
    }
    if (offset < 0 || count < 0 || offset > length - count) {
      throw RangeError(
        'VRLZ fd range [$offset..${offset + count}) exceeds $length.',
      );
    }
    return _posix.preadExact(_fd, offset, count);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final fd = _fd;
    _fd = -1;
    if (fd >= 0) {
      _posix.close(fd);
    }
  }
}

// ---------------------------------------------------------------------------
// FileRandomAccessSource (uses stateless POSIX `pread` when available, else RAF)
// ---------------------------------------------------------------------------

final class FileRandomAccessSource implements VrlzRandomAccessSource {
  FileRandomAccessSource._({
    required this.displayName,
    required this.length,
    PosixFdRandomAccessSource? posixSource,
    RandomAccessFile? raf,
  }) : _posixSource = posixSource,
       _raf = raf;

  final PosixFdRandomAccessSource? _posixSource;
  final RandomAccessFile? _raf;
  Future<void> _rafLock = Future<void>.value();
  bool _closed = false;

  @override
  final String displayName;

  @override
  final int length;

  @override
  bool get isClosed => _closed;

  static Future<FileRandomAccessSource> open(String path) async {
    final file = File(path);
    final name = path
        .replaceAll('\\', '/')
        .split('/')
        .where((s) => s.isNotEmpty)
        .lastOrNull ??
        'archive.vrlz';
    final posix = _PosixBindings.instance;
    if (posix != null) {
      final rawFd = posix.openReadOnlyPath(file.path);
      if (rawFd >= 0) {
        final size = posix.lseek(rawFd, 0, _PosixBindings.seekEnd);
        if (size >= 0) {
          return FileRandomAccessSource._(
            displayName: name,
            length: size,
            posixSource: PosixFdRandomAccessSource._(
              ownedFd: rawFd,
              length: size,
              displayName: name,
              posix: posix,
            ),
          );
        }
        posix.close(rawFd);
      }
    }
    final raf = await file.open(mode: FileMode.read);
    try {
      final size = await raf.length();
      return FileRandomAccessSource._(
        displayName: name,
        length: size,
        raf: raf,
      );
    } catch (_) {
      await raf.close();
      rethrow;
    }
  }

  @override
  Future<Uint8List> readRange(int offset, int count) {
    if (_closed) throw StateError('VRLZ file source is closed.');
    final posixSource = _posixSource;
    if (posixSource != null) {
      return posixSource.readRange(offset, count);
    }
    if (offset < 0 || count < 0 || offset > length - count) {
      throw RangeError(
        'VRLZ file range [$offset..${offset + count}) exceeds $length.',
      );
    }
    if (count == 0) return Future<Uint8List>.value(Uint8List(0));
    final prev = _rafLock;
    final completer = Future<Uint8List>(() async {
      await prev;
      if (_closed) throw StateError('VRLZ file source was closed.');
      final raf = _raf!;
      await raf.setPosition(offset);
      final out = Uint8List(count);
      var done = 0;
      while (done < count) {
        final got = await raf.readInto(out, done, count);
        if (got <= 0) {
          throw const FormatException('Unexpected EOF in VRLZ file.');
        }
        done += got;
      }
      return out;
    });
    _rafLock = completer.then((_) {}, onError: (_) {});
    return completer;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _posixSource?.close();
    await _raf?.close();
  }
}

// ---------------------------------------------------------------------------
// FileBackedTempBuffer (`unlink`-on-open + `mmap` `PROT_READ | MAP_PRIVATE`)
// ---------------------------------------------------------------------------

int _tempBufferSequence = 0;

final class FileBackedTempBufferSink implements VrlzTempBufferSink {
  FileBackedTempBufferSink({required this.expectedLength}) {
    if (expectedLength < 0) {
      throw ArgumentError.value(expectedLength, 'expectedLength');
    }
    if (expectedLength > 0) {
      final id = ++_tempBufferSequence;
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final file = File(
        '${Directory.systemTemp.path}/vrlz_spill_${pid}_${stamp}_$id.tmp',
      );
      _file = file;
      _raf = file.openSync(mode: FileMode.writeOnly);
    }
  }

  final int expectedLength;
  File? _file;
  RandomAccessFile? _raf;
  int _written = 0;
  bool _closed = false;

  @override
  void addSlice(Uint8List chunk, int start, int end) {
    if (_closed) throw StateError('Temp buffer sink already closed.');
    final count = end - start;
    if (count == 0) return;
    if (count < 0 || _written + count > expectedLength) {
      abort();
      throw const FormatException(
        'Decompressed VRLZ entry exceeds its declared byte budget.',
      );
    }
    _raf!.writeFromSync(chunk, start, end);
    _written += count;
  }

  @override
  VrlzTempBuffer finish() {
    if (_closed) throw StateError('Temp buffer sink already closed.');
    _closed = true;
    final raf = _raf;
    _raf = null;
    final file = _file;
    _file = null;
    try {
      raf?.flushSync();
      raf?.closeSync();
    } catch (_) {
      _safeDelete(file);
      rethrow;
    }
    if (_written != expectedLength) {
      _safeDelete(file);
      throw const FormatException('Temp buffer byte length mismatch.');
    }
    if (expectedLength == 0 || file == null) {
      return FileBackedTempBuffer._empty();
    }

    final posix = _PosixBindings.instance;
    if (posix != null) {
      final fd = posix.openReadOnlyPath(file.path);
      if (fd >= 0) {
        // Immediately unlink the directory entry while holding the open inode!
        // Zero temp files can ever leak even on hard process termination.
        _safeDelete(file);
        final addr = posix.mmap(
          0,
          expectedLength,
          _PosixBindings.protRead,
          _PosixBindings.mapPrivate,
          fd,
          0,
        );
        // POSIX guarantees the mapping remains valid after closing fd.
        posix.close(fd);
        if (addr != -1 && addr != 0) {
          return FileBackedTempBuffer._mapped(
            length: expectedLength,
            mapAddr: addr,
            posix: posix,
          );
        }
      }
    }

    // Fallback (e.g. Windows): keep RandomAccessFile and delete on close().
    final readRaf = file.openSync(mode: FileMode.read);
    return FileBackedTempBuffer._rafFallback(
      length: expectedLength,
      raf: readRaf,
      backingFile: file,
    );
  }

  @override
  void abort() {
    if (_closed) return;
    _closed = true;
    final raf = _raf;
    _raf = null;
    final file = _file;
    _file = null;
    try {
      raf?.closeSync();
    } catch (_) {}
    _safeDelete(file);
  }

  static void _safeDelete(File? file) {
    if (file == null) return;
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }
}

final class FileBackedTempBuffer implements VrlzTempBuffer {
  FileBackedTempBuffer._empty()
    : length = 0,
      isFileBacked = true,
      isMemoryMapped = false,
      _mapAddr = 0,
      _posix = null,
      _raf = null,
      _backingFile = null;

  FileBackedTempBuffer._mapped({
    required this.length,
    required int mapAddr,
    required _PosixBindings posix,
  }) : isFileBacked = true,
       isMemoryMapped = true,
       _mapAddr = mapAddr,
       _posix = posix,
       _raf = null,
       _backingFile = null;

  FileBackedTempBuffer._rafFallback({
    required this.length,
    required RandomAccessFile raf,
    required File backingFile,
  }) : isFileBacked = true,
       isMemoryMapped = false,
       _mapAddr = 0,
       _posix = null,
       _raf = raf,
       _backingFile = backingFile;

  @override
  final int length;

  @override
  final bool isFileBacked;

  @override
  final bool isMemoryMapped;

  int _mapAddr;
  final _PosixBindings? _posix;
  RandomAccessFile? _raf;
  File? _backingFile;
  bool _closed = false;

  @override
  bool get isClosed => _closed;

  @override
  Uint8List readBytesSync(int offset, int count) {
    if (_closed) throw StateError('File-backed VRLZ temp buffer is closed.');
    if (offset < 0 ||
        count < 0 ||
        count > VrlwByteSource.maxReadLength ||
        offset > length - count) {
      throw RangeError(
        'Temp buffer range [$offset..${offset + count}) exceeds $length.',
      );
    }
    if (count == 0) return Uint8List(0);
    if (isMemoryMapped && _mapAddr != 0) {
      final ptr = ffi.Pointer<ffi.Uint8>.fromAddress(_mapAddr + offset);
      return Uint8List.fromList(ptr.asTypedList(count));
    }
    final raf = _raf!;
    raf.setPositionSync(offset);
    final out = Uint8List(count);
    var done = 0;
    while (done < count) {
      final got = raf.readIntoSync(out, done, count);
      if (got <= 0) {
        throw const FormatException('Unexpected EOF in temp buffer fallback.');
      }
      done += got;
    }
    return out;
  }

  @override
  Future<Uint8List> readRange(int offset, int count) async =>
      readBytesSync(offset, count);

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final addr = _mapAddr;
    _mapAddr = 0;
    if (isMemoryMapped && addr != 0 && length > 0) {
      _posix?.munmap(addr, length);
    }
    final raf = _raf;
    _raf = null;
    try {
      raf?.closeSync();
    } catch (_) {}
    final file = _backingFile;
    _backingFile = null;
    if (file != null) {
      try {
        if (file.existsSync()) file.deleteSync();
      } catch (_) {}
    }
  }
}
