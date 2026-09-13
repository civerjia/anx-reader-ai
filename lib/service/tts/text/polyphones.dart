import 'package:anx_reader/service/tts/text/pronunciation_lexicon.dart';

/// Characters the system voice was heard reading the wrong way, marked with
/// the right reading (pinyin with a tone number) for the voice. The text is
/// left as it is where the mark sounds right: a homophone in its place would
/// leave it unclear which character was meant. Where the marked reading was
/// heard to sound off (露富, 女红), a homophone is spoken instead.
class Polyphones {
  static final List<(RegExp, String)> _homophones = [
    (RegExp(r'女红(?!军|男)'), '女工'),
    (RegExp(r'(?<![揭暴裸显透袒吐披流败表坦外展])露(?=富)'), '漏'),
  ];

  /// [text] with the homophones in place; marks are found on the result.
  static String rewrite(String text) {
    var result = text;
    for (final (pattern, homophone) in _homophones) {
      result = result.replaceAll(pattern, homophone);
    }
    return result;
  }

  /// Each rule matches the character to mark (or a word, with the offset of
  /// the character in it) and gives its reading.
  static final List<(RegExp, int, String)> _rules = [
    // 朝阳 is zhāo only as the morning sun. Word lists give it both readings:
    // places (朝阳区), 丹凤朝阳, 朝阳花 and facing the sun (向日葵朝阳开) are
    // cháo, and a name like 李朝阳 could be either, so only unmistakable
    // morning-sun phrases change.
    (
      RegExp(r'(?<=一轮|初升的|清晨的|早晨的|迎着|沐浴着)朝(?=阳)'
          r'|朝(?=阳(?:产业|般|似的|初升|升起|照|映|洒|染|的光|的余晖))'),
      0,
      'zhao1'
    ),
    // 曾 as a surname is zēng, otherwise céng (曾经).
    (RegExp(r'曾(?=家(?!境|乡|访)|先生|女士|老师|国藩|子|氏|姓|某|孙|祖|外祖)'), 0, 'zeng1'),
    // Heard misread on the phone: 女红 (gōng), 长出一口气 (cháng). 划拳 is
    // left as the voice says it, which the listener is used to.
    (RegExp(r'长(?=[出舒]了?一口气)'), 0, 'chang2'),
    // 露 is lòu in a handful of spoken words (the 1985 审音表 lists 露富,
    // 露苗, 露相, 露马脚), lù everywhere else: 抛头露面, 出头露面, and after
    // 揭 暴 裸 显 透… (揭露面积 is 揭露 + 面积).
    (
      RegExp(r'(?<![揭暴裸显透袒吐披流败表坦外展])(?<!抛头|出头)'
          r'露(?=了?[一两]手|脸|面(?!积|抛头)|馅|怯|马脚|相|丑|底|苗)'),
      0,
      'lou4'
    ),
  ];

  static List<PronunciationMark> marks(String text) => [
        for (final (pattern, offset, reading) in _rules)
          for (final match in pattern.allMatches(text))
            PronunciationMark(match.start + offset, reading),
      ];
}
