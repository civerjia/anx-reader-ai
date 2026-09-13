import 'package:anx_reader/service/tts/text/chemistry.dart';
import 'package:anx_reader/service/tts/text/chinese_number.dart';
import 'package:anx_reader/service/tts/text/speech_text.dart';
import 'package:flutter_test/flutter_test.dart';

String symbols(String text) => SpeechText.normalize(text);
String names(String text) =>
    SpeechText.normalize(text, formulas: FormulaReading.names);

void main() {
  group('chinese numbers', () {
    for (final (n, words) in const [
      (0, '零'), (7, '七'), (10, '十'), (12, '十二'), (20, '二十'), (105, '一百零五'),
      (110, '一百一十'), (1000, '一千'), (1024, '一千零二十四'), (10005, '一万零五'),
      (10010, '一万零一十'), (123456, '十二万三千四百五十六'),
    ]) {
      test('$n', () => expect(chineseNumber(n), words));
    }
  });

  group('misread by the system voice', () {
    test('powers of ten and per-units', () {
      expect(symbols('浓度为1×10⁻³ mol/L。'), '浓度为1乘十的负三次方摩尔每升。');
      expect(symbols('约1x10^-3 mol/L'), '约1乘十的负三次方摩尔每升');
      expect(symbols('约1×10-3mol/L'), '约1乘十的负三次方摩尔每升');
      expect(symbols('阿伏伽德罗常数约6.02×10²³'), '阿伏伽德罗常数约6.02乘十的二十三次方');
      expect(symbols('达到10⁶量级'), '达到十的六次方量级');
      expect(symbols('约1.6×10⁻¹⁹库仑'), '约1.6乘十的负十九次方库仑');
      expect(symbols('共10¹²⁰种'), '共十的一百二十次方种');
    });

    test('No.', () {
      expect(symbols('他在比赛中排名No.1。'), '他在比赛中排名第1。');
      expect(symbols('排名 No. 12'), '排名 第12');
    });

    test('formulas read letter by letter', () {
      expect(symbols('酸溶液中存在H3O+。'), '酸溶液中存在H 三 O 正离子。');
      expect(symbols('H₃O⁺就是水合氢离子。'), 'H 三 O 正离子就是水合氢离子。');
      expect(symbols('CO2是一种温室气体。'), 'C O 二是一种温室气体。');
      expect(symbols('NaCl易溶于水。'), 'N A C L易溶于水。');
      expect(symbols('溶液中的OH-浓度升高。'), '溶液中的O H 负离子浓度升高。');
      expect(symbols('SO₄²⁻与Ba²⁺生成沉淀。'), 'S O 四 二价负离子与B A 二价正离子生成沉淀。');
      expect(symbols('Fe3+的溶液呈黄色。'), 'F E 三价正离子的溶液呈黄色。');
      expect(symbols('醋酸CH3COOH是弱酸。'), '醋酸C H 三 C O O H是弱酸。');
      expect(symbols('反应式：2H2+O2=2H2O。'), '反应式：二 H 二 加 O 二 等于 二 H 二 O。');
    });

    test('formulas read by name', () {
      expect(names('酸溶液中存在H3O+。'), '酸溶液中存在水合氢离子。');
      expect(names('CO2是一种温室气体。'), '二氧化碳是一种温室气体。');
      expect(names('NaCl易溶于水。'), '氯化钠易溶于水。');
      expect(names('溶液中的OH-浓度升高。'), '溶液中的氢氧根离子浓度升高。');
      expect(names('SO₄²⁻与Ba²⁺生成沉淀。'), '硫酸根离子与钡离子生成沉淀。');
      expect(names('SO42-与Ba2+生成沉淀。'), '硫酸根离子与钡离子生成沉淀。');
      expect(names('Fe3+的溶液呈黄色。'), '三价铁离子的溶液呈黄色。');
      expect(names('醋酸CH3COOH是弱酸。'), '醋酸醋酸是弱酸。');
      expect(names('NH4+和NO3-'), '铵根离子和硝酸根离子');
      // Equations are always spelled: names would make them unreadable.
      expect(names('反应式：2H2+O2=2H2O。'), '反应式：二 H 二 加 O 二 等于 二 H 二 O。');
      // Unknown formulas fall back to letters.
      expect(names('K2Cr2O7是强氧化剂'), 'K 二 C R 二 O 七是强氧化剂');
    });
  });

  group('left alone', () {
    for (final text in const [
      '这本书出版于2024年。',
      '请升级到v2.1.3版本。',
      'iPhone 16 Pro用的是A18芯片。',
      'pH=7时溶液呈中性。',
      '这是一个B2B平台',
      '他考试拿了个B+',
      '维生素B12和U235',
      '4K屏幕和PS游戏机',
      'COVID-19疫情',
      'CPU和SUV',
      '他说He is fine',
      '温度为25℃，时速120km/h',
      'Nice的NBA比赛',
    ]) {
      test(text, () {
        expect(symbols(text), text);
        expect(names(text), text);
      });
    }

    test('text without Chinese', () {
      expect(symbols('H2O and No.1'), 'H2O and No.1');
    });
  });

  group('parsing', () {
    test('plain-text charges split from counts', () {
      expect(Chemistry.parse('Fe3+')!.key, 'Fe3+');
      expect(Chemistry.parse('SO42-')!.key, 'SO42-');
      expect(Chemistry.parse('NH4+')!.key, 'NH4+');
      expect(Chemistry.parse('Ca(OH)2')!.key, 'Ca(OH)2');
      expect(Chemistry.parse('Xy2'), isNull);
    });
  });
}
