/// Characters the system voice was heard reading with the wrong tone or
/// sound, swapped for a homophone that has only the intended reading. Only
/// the copy given to the voice changes. A homophone was chosen over a
/// pronunciation attribute because it was heard to work every time and needs
/// nothing from the voice.
class Polyphones {
  static final List<(RegExp, String)> _rules = [
    // 朝阳 as the morning sun is zhāo; the Beijing district, gate and city
    // are Cháoyáng.
    (RegExp(r'朝(?=阳(?!区|门|市|县|路|街|大街|公园|医院|剧场))'), '招'),
    // 曾 as a surname is zēng, otherwise céng (曾经).
    (RegExp(r'曾(?=家(?!境|乡)|先生|女士|老师|国藩|子|氏|姓|某)'), '增'),
    // 露 is lòu in a handful of spoken words, lù everywhere else (暴露, and
    // 抛头露面 per the 1985 审音表).
    (RegExp(r'(?<!抛头)露(?=了?一手|脸|面|馅|怯|富|马脚|相)'), '漏'),
  ];

  static String rewrite(String text) {
    var result = text;
    for (final (pattern, homophone) in _rules) {
      result = result.replaceAll(pattern, homophone);
    }
    return result;
  }
}
