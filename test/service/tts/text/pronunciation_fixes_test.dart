import 'dart:io';

import 'package:anx_reader/service/tts/text/pronunciation_fixes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const markFix = PronunciationFix(word: '露富', index: 0, reading: 'lou4');
  const homophoneFix = PronunciationFix(
      word: '女红', index: 1, reading: 'gong1', homophone: '工', useHomophone: true);

  group('applying fixes', () {
    test('marks every occurrence of a marked word', () {
      final marks = PronunciationFixes.marks('他不露富，也不露富', [markFix]);
      expect(marks.map((m) => (m.start, m.notation)), [(2, 'lou4'), (7, 'lou4')]);
    });

    test('speaks a homophone and marks nothing for it', () {
      final text = PronunciationFixes.rewrite('她学女红，爱女红', [homophoneFix, markFix]);
      expect(text, '她学女工，爱女工');
      expect(PronunciationFixes.marks(text, [homophoneFix]), isEmpty);
    });

    test('round-trips through a map and rejects broken entries', () {
      expect(PronunciationFix.fromMap(homophoneFix.toMap())!.toMap(), homophoneFix.toMap());
      expect(PronunciationFix.fromMap({'word': '露富', 'index': 5, 'reading': 'lou4'}), isNull);
      expect(PronunciationFix.fromMap({'word': '露富'}), isNull);
      // A homophone flag without a homophone falls back to the mark.
      expect(
          PronunciationFix.fromMap({'word': '露富', 'index': 0, 'reading': 'lou4', 'useHomophone': true})!
              .useHomophone,
          isFalse);
    });
  });

  group('readings', () {
    for (final (numbered, marked) in const [
      ('lou4', 'lòu'), ('lv4', 'lǜ'), ('nv3', 'nǚ'), ('gui4', 'guì'), ('liu2', 'liú'),
      ('de5', 'de'), ('er2', 'ér'), ('zhuang1', 'zhuāng'), ('xue2', 'xué'),
    ]) {
      test('$numbered is $marked', () => expect(toneMarked(numbered), marked));
    }

    final sample = CharReadings.parse([
      '露\tlu4:150,lou4:27\t177',
      '漏\tlou4:64,lou2:0\t64',
      '陋\tlou4:19\t19',
      '长\tzhang3:300,chang2:273\t573',
      '篓\tlou3:5\t5',
    ].join('\n'));

    test('homophones are characters read that way nearly always', () {
      expect(sample.homophones('lou4', except: '露'), ['漏', '陋']);
      expect(sample.homophones('zhang3'), isEmpty);
    });

    test('the usual reading is the most listed one', () {
      expect(sample.usual('露'), 'lu4');
      expect(sample.isPolyphonic('露'), isTrue);
      expect(sample.isPolyphonic('陋'), isFalse);
    });
  });

  final asset = File('assets/pronunciation/chars.txt');
  test('bundled readings offer common homophones', () {
    final chars = CharReadings.parse(asset.readAsStringSync());
    expect(chars.of('露'), containsAll(['lu4', 'lou4']));
    expect(chars.homophones('lou4', except: '露'), contains('漏'));
    expect(chars.homophones('gong1', except: '红'), contains('工'));
    expect(chars.homophones('zhang3'), isNot(contains('长')));
  }, skip: asset.existsSync() ? false : 'chars.txt not built');
}
