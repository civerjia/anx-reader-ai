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

  /// Speed to ask the model for, given the user's rate and the model's
  /// calibration factor (1.0 when nothing has been measured yet).
  static double speed({required double rate, required double factor}) {
    final effectiveRate = rate <= 0.05 ? referenceRate : rate;
    final speed = factor * effectiveRate / referenceRate;
    return speed.clamp(0.2, 3.0);
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
