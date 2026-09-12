import 'package:anx_reader/service/tts/sherpa/sherpa_pace.dart';

/// How many syllables of narration [by] covers at [rate].
///
/// Narration has no timeline to seek in: the system voice reads one sentence
/// at a time and says nothing about how long each takes. So "thirty seconds"
/// is turned into the amount of text that takes thirty seconds to say — about
/// four syllables a second at normal speed, the pace audiobooks are read at.
double syllablesFor(Duration by, double rate) =>
    by.inMilliseconds.abs() / 1000 * SherpaPace.referencePace * rate;

/// Steps through sentences until at least [syllables] have been passed, and
/// returns the sentence it stopped on — null when the book ran out first.
///
/// Each step moves the reader's narration position, so this only walks; it
/// never speaks, and the caller starts narration once from where it lands.
Future<String?> stepUntil({
  required Future<String?> Function() step,
  required double syllables,
}) async {
  var passed = 0.0;
  String? landed;
  while (true) {
    final text = await step();
    if (text == null || text.isEmpty) return landed;
    landed = text;
    passed += SherpaPace.syllables(text);
    if (passed >= syllables) return landed;
  }
}
