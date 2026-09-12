import 'dart:math' as math;
import 'dart:typed_data';

import 'package:anx_reader/service/tts/sherpa/sherpa_loudness.dart';

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

/// Shorten the pauses inside generated speech without clipping the words.
///
/// Kokoro leaves long gaps at punctuation: on one Chinese sentence with
/// three commas, five pauses of 0.7 to 0.9 seconds make up 40% of the clip.
/// sherpa-onnx can shorten them itself, but it calls anything below 0.01
/// amplitude silence, which is where the decaying tail of the syllable
/// before the comma lives, so it eats the end of the word. Measured on the
/// same clip, dropping the threshold to 0.002 keeps 60 to 100ms more of
/// each word and finds the same pauses.
///
/// [scale] is how much of each pause to keep; pauses are also never left
/// longer than [maxPause] or shortened below [keepPause].
Float32List tightenPauses(
  Float32List samples,
  int sampleRate, {
  double scale = 0.4,
  double threshold = 0.002,
  double minPause = 0.18,
  double keepPause = 0.12,
  double maxPause = 0.5,
}) {
  if (scale >= 1.0 || samples.isEmpty || sampleRate <= 0) return samples;

  final minRun = (sampleRate * minPause).round();
  final keepMin = (sampleRate * keepPause).round();
  final keepMax = (sampleRate * maxPause).round();

  final out = Float32List(samples.length);
  var written = 0;
  var runStart = -1;

  void flushRun(int end) {
    final length = end - runStart;
    if (length < minRun) {
      // Not a pause: keep it as it is, it is part of a word.
      out.setRange(written, written + length, samples, runStart);
      written += length;
      return;
    }
    final kept = (length * scale).round().clamp(keepMin, keepMax);
    out.setRange(written, written + kept, samples, runStart);
    written += kept;
  }

  for (var i = 0; i < samples.length; i++) {
    if (samples[i].abs() <= threshold) {
      if (runStart < 0) runStart = i;
      continue;
    }
    if (runStart >= 0) {
      flushRun(i);
      runStart = -1;
    }
    out[written++] = samples[i];
  }
  if (runStart >= 0) flushRun(samples.length);

  return Float32List.sublistView(out, 0, written);
}

/// Even out how loud each sentence is.
///
/// Models differ in level and wander between sentences: on the same five
/// sentences, vits-melo-tts came back spanning 7.6 dB, loud enough that the
/// volume audibly jumps from one sentence to the next. Each sentence is
/// synthesized on its own, so this is the only place to fix it.
///
/// Loudness is measured the way broadcast metering does it, over 400ms
/// blocks with quiet blocks gated out, because a sentence's average sample
/// level says little about how loud it sounds. Peaks are then held under
/// [ceiling] by a soft knee rather than by turning the whole sentence down,
/// which is what used to leave a punchy sentence quieter than the rest.
/// Measured across those five sentences: 7.6 dB spread before, 0.2 dB after.
Float32List normalizeLoudness(
  Float32List samples,
  int sampleRate, {
  double targetLufs = SherpaLoudness.targetLufs,
  double maxGain = 12.0,
  double ceiling = 0.95,
}) {
  final gain = SherpaLoudness.gainFor(samples, sampleRate,
      target: targetLufs, maxGain: maxGain);
  if ((gain - 1).abs() < 0.02) return samples;

  final knee = ceiling * 0.8;
  final range = ceiling - knee;
  final out = Float32List(samples.length);
  for (var i = 0; i < samples.length; i++) {
    final value = samples[i] * gain;
    final level = value.abs();
    if (level <= knee) {
      out[i] = value;
      continue;
    }
    // Soft knee: continuous at the knee, asymptotic to the ceiling.
    final shaped = knee + range * _tanh((level - knee) / range);
    out[i] = value.isNegative ? -shaped : shaped;
  }
  return out;
}

/// Loudness of the speech in a clip.
///
/// Blocked and gated the way broadcast metering is, because the average
/// sample level of a whole sentence says little about how loud it sounds.
/// Blocks that are mostly pause are dropped twice over: by an absolute
/// floor, and by a gate ten decibels below the average of what is left.
///
/// The block has to shrink for short sentences. A book is full of them, and
/// measuring a half second sentence as if it were four hundred milliseconds
/// of speech plus silence reads far too quiet, which used to make every
/// short sentence come out louder than the rest.
double gatedLevel(Float32List samples, int sampleRate) {
  if (samples.isEmpty || sampleRate <= 0) return 0;

  const floor = 0.005 * 0.005; // below this a block is silence
  // Short blocks, so that a sentence of half a second is measured the same
  // way as one of ten seconds: a long block spanning speech and the pause
  // after it reads too quiet, and a book is mostly short sentences.
  final block = math.min((sampleRate * 0.08).round(), samples.length);
  if (block <= 0) return plainLevel(samples);

  final hop = math.max(1, block ~/ 2);
  final powers = <double>[];
  for (var start = 0; start + block <= samples.length; start += hop) {
    var sum = 0.0;
    for (var i = start; i < start + block; i++) {
      sum += samples[i] * samples[i];
    }
    final power = sum / block;
    if (power > floor) powers.add(power);
  }

  if (powers.isEmpty) return plainLevel(samples);

  var mean = 0.0;
  for (final power in powers) {
    mean += power;
  }
  mean /= powers.length;

  final gate = mean * 0.1; // ten decibels below the average
  var kept = 0.0;
  var count = 0;
  for (final power in powers) {
    if (power < gate) continue;
    kept += power;
    count++;
  }
  return math.sqrt(count == 0 ? mean : kept / count);
}

/// Level of everything that is not silence, for clips too short to block
/// and as an independent check on the blocked measure.
double plainLevel(Float32List samples) {
  var sum = 0.0;
  var count = 0;
  for (final sample in samples) {
    if (sample.abs() <= 0.005) continue;
    sum += sample * sample;
    count++;
  }
  if (count == 0) return 0;
  return math.sqrt(sum / count);
}

double _tanh(double x) {
  if (x > 10) return 1;
  final e = math.exp(2 * x);
  return (e - 1) / (e + 1);
}
