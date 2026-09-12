import 'dart:math' as math;
import 'dart:typed_data';

/// Loudness the way ears hear it, following ITU-R BS.1770.
///
/// Sentence to sentence, equal average level does not mean equal loudness:
/// speech with more energy around a few kHz sounds louder than the same
/// level down low, so sentences normalised to equal RMS still step up and
/// down. BS.1770 answers that with a weighting filter and a gate, and is
/// what broadcast and streaming use for the same problem.
class SherpaLoudness {
  /// What a sentence is normalised to, in LUFS. Around where audiobooks and
  /// podcasts sit, and low enough to leave room for peaks.
  static const double targetLufs = -20.0;

  /// Blocks quieter than this carry no speech.
  static const double absoluteGate = -70.0;

  /// Integrated loudness of [samples] in LUFS, or null when there is no
  /// speech to measure.
  static double? measure(Float32List samples, int sampleRate) {
    if (samples.isEmpty || sampleRate <= 0) return null;

    final weighted = _kWeight(samples, sampleRate);
    final block = (sampleRate * 0.4).round();
    if (block <= 0) return null;
    final hop = math.max(1, (block * 0.25).round());

    final powers = <double>[];
    for (var start = 0; start + block <= weighted.length; start += hop) {
      var sum = 0.0;
      for (var i = start; i < start + block; i++) {
        sum += weighted[i] * weighted[i];
      }
      powers.add(sum / block);
    }
    if (powers.isEmpty) {
      // Shorter than one block: measure what there is.
      var sum = 0.0;
      for (final sample in weighted) {
        sum += sample * sample;
      }
      final power = sum / weighted.length;
      return power <= 0 ? null : _loudness(power);
    }

    final loud = powers.where((power) => power > 0).toList();
    if (loud.isEmpty) return null;

    // Absolute gate, then a gate ten units below what is left.
    final aboveFloor =
        loud.where((power) => _loudness(power) > absoluteGate).toList();
    if (aboveFloor.isEmpty) return null;

    final relativeGate = _loudness(_mean(aboveFloor)) - 10;
    final kept = aboveFloor
        .where((power) => _loudness(power) > relativeGate)
        .toList();

    return _loudness(_mean(kept.isEmpty ? aboveFloor : kept));
  }

  /// Gain that brings [samples] to [targetLufs], limited to [maxGain].
  static double gainFor(
    Float32List samples,
    int sampleRate, {
    double target = targetLufs,
    double maxGain = 12.0,
  }) {
    final measured = measure(samples, sampleRate);
    if (measured == null) return 1;
    final gain = math.pow(10, (target - measured) / 20).toDouble();
    return gain.clamp(1 / maxGain, maxGain);
  }

  static double _mean(List<double> values) {
    var sum = 0.0;
    for (final value in values) {
      sum += value;
    }
    return sum / values.length;
  }

  static double _loudness(double power) =>
      -0.691 + 10 * (math.log(power) / math.ln10);

  /// The two stage K weighting of BS.1770: a high shelf that lifts the
  /// presence region, then a high pass that discards rumble. Coefficients
  /// are derived for the actual sample rate rather than assuming 48kHz.
  static Float32List _kWeight(Float32List samples, int sampleRate) {
    final shelf = _highShelf(1681.974450955533, 0.7071752369554196, 3.999843853973347, sampleRate);
    final highPass = _highPass(38.13547087602444, 0.5003270373238773, sampleRate);
    return _biquad(_biquad(samples, shelf), highPass);
  }

  static List<double> _highShelf(
      double frequency, double q, double gainDb, int sampleRate) {
    final a = math.pow(10, gainDb / 40).toDouble();
    final w0 = 2 * math.pi * frequency / sampleRate;
    final cosW0 = math.cos(w0);
    final alpha = math.sin(w0) / (2 * q);
    final sqrtA = math.sqrt(a);

    final b0 = a * ((a + 1) + (a - 1) * cosW0 + 2 * sqrtA * alpha);
    final b1 = -2 * a * ((a - 1) + (a + 1) * cosW0);
    final b2 = a * ((a + 1) + (a - 1) * cosW0 - 2 * sqrtA * alpha);
    final a0 = (a + 1) - (a - 1) * cosW0 + 2 * sqrtA * alpha;
    final a1 = 2 * ((a - 1) - (a + 1) * cosW0);
    final a2 = (a + 1) - (a - 1) * cosW0 - 2 * sqrtA * alpha;

    return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0];
  }

  static List<double> _highPass(double frequency, double q, int sampleRate) {
    final w0 = 2 * math.pi * frequency / sampleRate;
    final cosW0 = math.cos(w0);
    final alpha = math.sin(w0) / (2 * q);

    final b0 = (1 + cosW0) / 2;
    final b1 = -(1 + cosW0);
    final b2 = (1 + cosW0) / 2;
    final a0 = 1 + alpha;
    final a1 = -2 * cosW0;
    final a2 = 1 - alpha;

    return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0];
  }

  static Float32List _biquad(Float32List input, List<double> c) {
    final out = Float32List(input.length);
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0;
    for (var i = 0; i < input.length; i++) {
      final x0 = input[i];
      final y0 = c[0] * x0 + c[1] * x1 + c[2] * x2 - c[3] * y1 - c[4] * y2;
      x2 = x1;
      x1 = x0;
      y2 = y1;
      y1 = y0;
      out[i] = y0;
    }
    return out;
  }
}
