/// How the model and the player share the job of reaching a pace.
class SherpaSpeed {
  const SherpaSpeed({required this.model, required this.playback});

  /// Passed to sherpa-onnx as the generation speed.
  final double model;

  /// Applied to the player on top of it.
  final double playback;

  @override
  String toString() => 'model ${model.toStringAsFixed(2)}, '
      'playback ${playback.toStringAsFixed(2)}';
}

/// Turns Anx's rate slider into a speed factor that sounds the same whatever
/// local model is loaded.
///
/// Models differ a lot in how fast they talk at `speed: 1.0` — measured on
/// the same Chinese paragraph, Kokoro runs about 3.1 syllables per second,
/// vits-zh-aishell3 about 3.7 and a ZipVoice clone about 2.3 — so one rate
/// setting cannot mean the same thing for all of them. Anx measures the pace
/// of the first sentences a model produces and scales later requests so the
/// slider lands on a comparable pace.
class SherpaPace {
  /// Syllables per second the slider aims for at [referenceRate].
  ///
  /// Roughly the pace of an audiobook narrator, and close to what the system
  /// voices produce at the same slider value, so switching services does not
  /// change how fast the book is read.
  static const double referencePace = 4.0;

  /// The rate slider value that means "normal speed". Matches flutter_tts,
  /// where 0.5 is the platform's default rate.
  static const double referenceRate = 0.5;

  /// Enough measured speech to trust the estimate.
  static const double minSyllablesToCalibrate = 25;

  /// A factor outside this range means the measurement went wrong.
  static const double minFactor = 0.6;
  static const double maxFactor = 1.8;

  /// Rough syllable count: one per CJK character or kana, and about 1.4 per
  /// Latin word. Good enough to compare a model against itself.
  static double syllables(String text) {
    var cjk = 0;
    for (final rune in text.runes) {
      final isHan = rune >= 0x4E00 && rune <= 0x9FFF ||
          rune >= 0x3400 && rune <= 0x4DBF ||
          rune >= 0xF900 && rune <= 0xFAFF;
      final isKana = rune >= 0x3040 && rune <= 0x30FF;
      final isHangul = rune >= 0xAC00 && rune <= 0xD7AF;
      if (isHan || isKana || isHangul) cjk++;
    }
    final words = RegExp(r"[A-Za-z][A-Za-z'’]*").allMatches(text).length;
    return cjk + words * 1.4;
  }

  /// Fastest the model itself is asked to talk.
  ///
  /// Kokoro starts slurring and dropping syllables before pauses when it is
  /// pushed much beyond this, which is exactly where audiobook listeners
  /// live, so speed past this point comes from the player instead.
  static const double maxModelSpeed = 1.25;

  /// Slowest, below which the model drawls.
  static const double minModelSpeed = 0.5;

  /// How to reach the pace the user asked for: part from the model, the
  /// rest from the player.
  ///
  /// The model handles moderate changes best, since it re-times the speech
  /// rather than stretching a waveform. Past [maxModelSpeed] it starts
  /// losing syllables, so the remainder is handed to the player, which
  /// resamples with the pitch kept and never drops a sound.
  static SherpaSpeed split({required double rate, required double factor}) {
    final effectiveRate = rate <= 0.05 ? referenceRate : rate;
    final desired = (factor * effectiveRate / referenceRate).clamp(0.2, 4.0);
    final model = desired.clamp(minModelSpeed, maxModelSpeed);
    final playback = (desired / model).clamp(0.4, 3.0);
    return SherpaSpeed(model: model, playback: playback);
  }

  /// Calibration factor from measured speech, or null when there is not
  /// enough of it yet.
  ///
  /// [naturalSeconds] is the audio length the model would have produced at
  /// `speed: 1.0`, i.e. the measured length multiplied by the speed used.
  static double? factorFrom({
    required double syllables,
    required double naturalSeconds,
  }) {
    if (syllables < minSyllablesToCalibrate || naturalSeconds <= 0) return null;
    final pace = syllables / naturalSeconds;
    if (pace <= 0) return null;
    return (referencePace / pace).clamp(minFactor, maxFactor);
  }
}
