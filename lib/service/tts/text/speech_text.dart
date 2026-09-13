import 'package:anx_reader/service/tts/text/chemistry.dart';
import 'package:anx_reader/service/tts/text/chinese_number.dart';
import 'package:anx_reader/service/tts/text/polyphones.dart';

/// Rewrites Chinese text before a system voice reads it, for what the voice
/// was heard to get wrong: powers of ten, per-units, "No.", and chemical
/// formulas. Numbers the voice already reads well are left alone.
class SpeechText {
  static final _han = RegExp(r'[一-鿿]');
  static const _superscripts = '⁰¹²³⁴⁵⁶⁷⁸⁹';

  /// 1×10⁻³, 1x10^-3, 1×10-3.
  static final _scientific = RegExp(
      r'(\d+(?:\.\d+)?)\s*[×xX*]\s*10\s*(?:\^\s*([-−+]?\d+)|([⁻⁺]?[⁰¹²³⁴⁵⁶⁷⁸⁹]+)|([-−]\d+))');

  /// 10⁻³ on its own.
  static final _power = RegExp(r'(?<![\d.])10([⁻⁺]?[⁰¹²³⁴⁵⁶⁷⁸⁹]+)');

  static final _perUnit = RegExp(
      r'(?<=[\d⁰¹²³⁴-⁹])\s*(mmol/L|mol/L|mg/mL|g/mL|mg/L|g/L|g/cm³|g/cm3|kg/m³|kg/m3|m/s²|m/s2|m/s)(?![A-Za-z])');
  static const _perUnits = {
    'mmol/L': '毫摩尔每升',
    'mol/L': '摩尔每升',
    'mg/mL': '毫克每毫升',
    'g/mL': '克每毫升',
    'mg/L': '毫克每升',
    'g/L': '克每升',
    'g/cm³': '克每立方厘米',
    'g/cm3': '克每立方厘米',
    'kg/m³': '千克每立方米',
    'kg/m3': '千克每立方米',
    'm/s²': '米每二次方秒',
    'm/s2': '米每二次方秒',
    'm/s': '米每秒',
  };

  /// A four-digit count before a measure word, which the voice reads digit
  /// by digit like a year: 2024箱 → 两千零二十四箱. Years (2024年) and
  /// four-digit numbers elsewhere are left to the voice, which reads them
  /// right.
  static final _count = RegExp(
      r'(?<![\d.,:/\-A-Za-z])([1-9]\d{3})(?=多?(?:个|箱|人|名|位|只|件|本|元|块|次|条|张|台|辆|吨|千克|公斤|克|公里|千米|米|家|所|户|头|匹|棵|座|间|股|份|页|篇|首|部|项|种|粒|滴|斤|亩|册|套|双|对|架|艘|枚|支|把|根|层|级|天|小时|分钟|周|岁|倍))');

  static final _numberSign = RegExp(r'(?<![A-Za-z])(?:No|NO|no)\.\s*(\d+)');

  static String normalize(
    String text, {
    FormulaReading formulas = FormulaReading.symbols,
  }) {
    if (!_han.hasMatch(text)) return text;
    // Units first: the number before them is rewritten next.
    var result = text.replaceAllMapped(_perUnit, (m) => _perUnits[m[1]]!);
    result = result.replaceAllMapped(_scientific, (m) {
      final exponent = m[2] ?? m[4] ?? _fromSuperscript(m[3]!);
      return '${m[1]}乘${_powerOfTen(exponent)}';
    });
    result = result.replaceAllMapped(
        _power, (m) => _powerOfTen(_fromSuperscript(m[1]!)));
    result = result.replaceAllMapped(_numberSign, (m) => '第${m[1]}');
    result = result.replaceAllMapped(
        _count, (m) => chineseCount(int.parse(m[1]!)));
    result = Polyphones.rewrite(result);
    return Chemistry.rewrite(result, formulas);
  }

  static String _fromSuperscript(String s) => s
      .replaceAll('⁻', '-')
      .replaceAll('⁺', '')
      .split('')
      .map((c) => _superscripts.contains(c) ? '${_superscripts.indexOf(c)}' : c)
      .join();

  static String _powerOfTen(String exponent) {
    final value = int.parse(exponent.replaceAll('−', '-').replaceAll('+', ''));
    return '十的${value < 0 ? '负' : ''}${chineseNumber(value.abs())}次方';
  }
}
