import 'package:anx_reader/service/tts/sherpa/sherpa_pace.dart';
import 'package:anx_reader/service/tts/tts_skip.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('how much text thirty seconds is', () {
    test('about four syllables a second at normal speed', () {
      expect(syllablesFor(const Duration(seconds: 30), 1.0),
          30 * SherpaPace.referencePace);
    });

    test('scales with speed, and backwards is the same amount', () {
      final forward = syllablesFor(const Duration(seconds: 30), 2.0);
      final back = syllablesFor(const Duration(seconds: -30), 2.0);
      expect(forward, 2 * syllablesFor(const Duration(seconds: 30), 1.0));
      expect(back, forward);
    });
  });

  group('stepping through sentences', () {
    test('stops on the sentence that covers the distance', () async {
      final sentences = ['一二三四五', '六七八九十', '十一十二十三十四十五', '十六'];
      var i = 0;
      final landed = await stepUntil(
        step: () async => i < sentences.length ? sentences[i++] : null,
        syllables: 8,
      );
      expect(landed, '六七八九十');
      expect(i, 2, reason: 'no sentence past the target is visited');
    });

    test('at the end of the book it lands on the last sentence', () async {
      final sentences = ['一二三', '四五'];
      var i = 0;
      final landed = await stepUntil(
        step: () async => i < sentences.length ? sentences[i++] : '',
        syllables: 100,
      );
      expect(landed, '四五');
    });

    test('already at the end, there is nowhere to land', () async {
      final landed = await stepUntil(step: () async => null, syllables: 10);
      expect(landed, isNull);
    });
  });
}
