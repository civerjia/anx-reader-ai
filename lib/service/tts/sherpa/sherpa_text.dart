/// Turns symbols a TTS lexicon does not know into words it does.
///
/// sherpa-onnx ships rule FSTs for numbers, dates and phone numbers, but
/// nothing for symbols: Kokoro maps an unknown character to `❓`, which is
/// not in its token table, so `1%` comes out as `1` at best and as silence
/// at worst when the whole sentence is symbols.
class SherpaText {
  static final RegExp _han = RegExp(r'[一-鿿]');
  static final RegExp _percent = RegExp(r'(\d+(?:\.\d+)?)\s*%');
  static final RegExp _rangeDash = RegExp(r'(\d)\s*[~～—–]\s*(\d)');

  /// Symbols read the same way wherever they appear.
  static const Map<String, String> _chineseSymbols = {
    '℃': '摄氏度',
    '°C': '摄氏度',
    '℉': '华氏度',
    '&': '和',
    '×': '乘以',
    '÷': '除以',
    '±': '正负',
    '≈': '约等于',
    '≤': '小于等于',
    '≥': '大于等于',
    '\$': '美元',
    '€': '欧元',
    '£': '英镑',
  };

  static const Map<String, String> _englishSymbols = {
    '℃': ' degrees Celsius',
    '°C': ' degrees Celsius',
    '℉': ' degrees Fahrenheit',
    '&': ' and ',
    '×': ' times ',
    '÷': ' divided by ',
    '±': ' plus or minus ',
    '≈': ' approximately ',
    '≤': ' at most ',
    '≥': ' at least ',
    '€': ' euros',
    '£': ' pounds',
  };

  /// Rewrite [text] so a lexicon based model can read it aloud.
  static String normalize(String text) {
    final chinese = _han.hasMatch(text);
    var result = text;

    // Percentages are said the other way round in Chinese: 25% is
    // 百分之二十五, so the number has to move behind the word.
    result = result.replaceAllMapped(
      _percent,
      (match) => chinese ? '百分之${match[1]}' : '${match[1]} percent',
    );

    result = result.replaceAllMapped(
      _rangeDash,
      (match) => chinese ? '${match[1]}到${match[2]}' : '${match[1]} to ${match[2]}',
    );

    final symbols = chinese ? _chineseSymbols : _englishSymbols;
    symbols.forEach((symbol, word) {
      result = result.replaceAll(symbol, word);
    });

    if (!chinese) {
      // "$5" reads as "5 dollars", so the symbol moves behind its number.
      result = result.replaceAllMapped(
        RegExp(r'\$\s*(\d+(?:\.\d+)?)'),
        (match) => '${match[1]} dollars',
      );
    }

    return result;
  }
}
