import 'package:anx_reader/service/tts/text/chemistry.dart';
import 'package:anx_reader/service/tts/text/chinese_number.dart';

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
