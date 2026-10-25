import 'dart:typed_data';

/// Small canonical PCM subset for local ambient playback. This bounds decoded
/// native allocations as well as compressed VRLW resource bytes.
abstract final class VrlwAudioPolicy {
  static const maxBytes = 256 * 1024;
  static const maxSeconds = 8;
  static const sampleRates = {16000, 22050};

  static ({int sampleRate, int frameCount, Duration duration}) validate(
    Uint8List wav,
  ) {
    Never fail() => throw const FormatException('Unsupported ambient WAV.');
    if (wav.length < 46 || wav.length > maxBytes) fail();
    final d = ByteData.sublistView(wav);
    if (d.getUint32(0, Endian.little) != 0x46464952 ||
        d.getUint32(4, Endian.little) != wav.length - 8 ||
        d.getUint32(8, Endian.little) != 0x45564157 ||
        d.getUint32(12, Endian.little) != 0x20746d66 ||
        d.getUint32(16, Endian.little) != 16 ||
        d.getUint16(20, Endian.little) != 1 ||
        d.getUint16(22, Endian.little) != 1 ||
        d.getUint16(32, Endian.little) != 2 ||
        d.getUint16(34, Endian.little) != 16 ||
        d.getUint32(36, Endian.little) != 0x61746164) {
      fail();
    }
    final rate = d.getUint32(24, Endian.little);
    final pcmBytes = d.getUint32(40, Endian.little);
    if (!sampleRates.contains(rate) ||
        d.getUint32(28, Endian.little) != rate * 2 ||
        pcmBytes != wav.length - 44 ||
        pcmBytes == 0 ||
        pcmBytes.isOdd ||
        pcmBytes ~/ 2 > rate * maxSeconds) {
      fail();
    }
    final frames = pcmBytes ~/ 2;
    return (
      sampleRate: rate,
      frameCount: frames,
      duration: Duration(microseconds: frames * 1000000 ~/ rate),
    );
  }
}
