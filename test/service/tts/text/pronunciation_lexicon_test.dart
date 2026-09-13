import 'dart:io';

import 'package:anx_reader/service/tts/text/pronunciation_lexicon.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, String> marked(PronunciationLexicon lexicon, String text) => {
      for (final m in lexicon.marks(text)) '${text[m.start]}${m.start}': m.notation,
    };

void main() {
  group('segmentation', () {
    final lexicon = PronunciationLexicon.parse([
      '银行\t_ hang2',
      '在行\t_ hang2',
      '行走\txing2 _',
      '抛头露面\t_ _ lu4 _',
      '露面\tlou4 _',
      '朝阳',
      '绿林\tlv4 _',
      '钥匙\t_ shi5',
    ].join('\n'));

    test('leaves neutral tones to the voice', () {
      expect(marked(lexicon, '找钥匙'), isEmpty);
    });

    test('marks the longest word', () {
      expect(marked(lexicon, '他不愿抛头露面。'), {'露5': 'lu4'});
      expect(marked(lexicon, '他很少露面。'), {'露3': 'lou4'});
    });

    test('skips words that cross each other', () {
      // 在行 and 行走 overlap: either could be right, so neither is marked.
      expect(marked(lexicon, '有人在行走'), isEmpty);
      expect(marked(lexicon, '有人行走'), {'行2': 'xing2'});
    });

    test('leaves words with several readings to the voice', () {
      expect(marked(lexicon, '朝阳照着大地'), isEmpty);
    });

    test('marks ü only once its notation is known', () {
      PronunciationLexicon.umlaut = null;
      expect(marked(lexicon, '绿林好汉'), isEmpty);
      PronunciationLexicon.umlaut = 'v';
      expect(marked(lexicon, '绿林好汉'), {'绿0': 'lv4'});
      PronunciationLexicon.umlaut = null;
    });
  });

  final asset = File('assets/pronunciation/lexicon.txt');
  group('bundled lexicon', () {
    late final lexicon = PronunciationLexicon.parse(asset.readAsStringSync());

    for (final (text, expected) in const [
      ('他不愿抛头露面。', {'露5': 'lu4'}),
      ('他就爱露富。', {'露3': 'lou4'}),
      ('他装模作样地笑了。', {'模2': 'mu2'}),
      ('两个人一模一样。', {'模4': 'mu2'}),
      ('这是呕心沥血之作。', {'血5': 'xue4'}),
      ('学习不能一曝十寒。', {'曝5': 'pu4'}),
      ('他们是一丘之貉。', {'貉6': 'he2'}),
      ('大家都忍俊不禁。', {'禁6': 'jin1'}),
      ('他的传记很精彩。', {'传2': 'zhuan4'}),
    ]) {
      test(text, () {
        final marks = marked(lexicon, text);
        expected.forEach((key, value) => expect(marks[key], value, reason: '$marks'));
      });
    }

    test('common readings and tone sandhi are left to the voice', () {
      expect(marked(lexicon, '有人在行走'), isEmpty);
      expect(marked(lexicon, '两个人一模一样。').keys, ['模4']);
    });
  }, skip: asset.existsSync() ? false : 'lexicon not built');
}
