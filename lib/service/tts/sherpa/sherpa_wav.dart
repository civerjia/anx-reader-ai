import 'dart:typed_data';

/// Mono PCM samples decoded from a wave file.
class WavData {
  const WavData({required this.samples, required this.sampleRate});

  final Float32List samples;
  final int sampleRate;
}

/// Encode mono float samples (in [-1, 1]) as 16 bit PCM wave bytes.
///
/// sherpa-onnx hands back raw samples, while the TTS pipeline plays
/// [Uint8List] through audioplayers, so every generated sentence is wrapped
/// in a RIFF header here.
Uint8List encodeWav(Float32List samples, int sampleRate) {
  const numChannels = 1;
  const bitsPerSample = 16;
  final byteRate = sampleRate * numChannels * bitsPerSample ~/ 8;
  final blockAlign = numChannels * bitsPerSample ~/ 8;
  final dataSize = samples.length * 2;
  final totalSize = 44 + dataSize;

  final buffer = Uint8List(totalSize);
  final bd = buffer.buffer.asByteData();

  buffer.setRange(0, 4, 'RIFF'.codeUnits);
  bd.setUint32(4, totalSize - 8, Endian.little);
  buffer.setRange(8, 12, 'WAVE'.codeUnits);

  buffer.setRange(12, 16, 'fmt '.codeUnits);
  bd.setUint32(16, 16, Endian.little);
  bd.setUint16(20, 1, Endian.little); // PCM
  bd.setUint16(22, numChannels, Endian.little);
  bd.setUint32(24, sampleRate, Endian.little);
  bd.setUint32(28, byteRate, Endian.little);
  bd.setUint16(32, blockAlign, Endian.little);
  bd.setUint16(34, bitsPerSample, Endian.little);

  buffer.setRange(36, 40, 'data'.codeUnits);
  bd.setUint32(40, dataSize, Endian.little);

  for (var i = 0; i < samples.length; i++) {
    final s = (samples[i] * 32767).clamp(-32768.0, 32767.0).toInt();
    bd.setInt16(44 + i * 2, s, Endian.little);
  }

  return buffer;
}

/// Decode wave bytes into mono float samples.
///
/// Supports 16 bit PCM and 32 bit float PCM, mono or multi channel (extra
/// channels are averaged). Returns null when the format is not supported,
/// which is reported to the user as an invalid reference audio.
WavData? decodeWav(Uint8List bytes) {
  if (bytes.length < 44) return null;
  final bd = bytes.buffer.asByteData(bytes.offsetInBytes, bytes.lengthInBytes);

  String tag(int offset) =>
      String.fromCharCodes(bytes.sublist(offset, offset + 4));

  if (tag(0) != 'RIFF' || tag(8) != 'WAVE') return null;

  int audioFormat = 0;
  int numChannels = 0;
  int sampleRate = 0;
  int bitsPerSample = 0;
  Uint8List? dataBytes;

  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final chunkId = tag(offset);
    final chunkSize = bd.getUint32(offset + 4, Endian.little);
    if (chunkId == 'fmt ' && offset + 8 + 16 <= bytes.length) {
      audioFormat = bd.getUint16(offset + 8, Endian.little);
      numChannels = bd.getUint16(offset + 10, Endian.little);
      sampleRate = bd.getUint32(offset + 12, Endian.little);
      bitsPerSample = bd.getUint16(offset + 22, Endian.little);
    } else if (chunkId == 'data') {
      final end = offset + 8 + chunkSize;
      final size = end <= bytes.length ? chunkSize : bytes.length - offset - 8;
      if (size <= 0) return null;
      dataBytes =
          Uint8List.view(bytes.buffer, bytes.offsetInBytes + offset + 8, size);
    }
    // Chunks are word aligned.
    offset += 8 + chunkSize + (chunkSize.isOdd ? 1 : 0);
  }

  if (dataBytes == null || numChannels <= 0 || sampleRate <= 0) return null;
  final dbd = dataBytes.buffer
      .asByteData(dataBytes.offsetInBytes, dataBytes.lengthInBytes);

  if (audioFormat == 1 && bitsPerSample == 16) {
    final numSamples = dataBytes.length ~/ (2 * numChannels);
    final samples = Float32List(numSamples);
    for (var i = 0; i < numSamples; i++) {
      var sum = 0.0;
      for (var ch = 0; ch < numChannels; ch++) {
        sum += dbd.getInt16((i * numChannels + ch) * 2, Endian.little) / 32768.0;
      }
      samples[i] = sum / numChannels;
    }
    return WavData(samples: samples, sampleRate: sampleRate);
  }

  if (audioFormat == 3 && bitsPerSample == 32) {
    final numSamples = dataBytes.length ~/ (4 * numChannels);
    final samples = Float32List(numSamples);
    for (var i = 0; i < numSamples; i++) {
      var sum = 0.0;
      for (var ch = 0; ch < numChannels; ch++) {
        sum += dbd.getFloat32((i * numChannels + ch) * 4, Endian.little);
      }
      samples[i] = sum / numChannels;
    }
    return WavData(samples: samples, sampleRate: sampleRate);
  }

  return null;
}
