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

    test('four-digit counts', () {
      expect(symbols('仓库里有2024箱货。'), '仓库里有两千零二十四箱货。');
      expect(symbols('来了1500多人'), '来了一千五百多人');
      expect(symbols('这本书出版于2024年。'), '这本书出版于2024年。');
      expect(symbols('2024届毕业生'), '2024届毕业生');
      expect(symbols('编号12345个'), '编号12345个');
    });

    test('polyphones', () {
      expect(symbols('朝阳照着古代的朝廷。'), '招阳照着古代的朝廷。');
      expect(symbols('他住在朝阳区'), '他住在朝阳区');
      expect(symbols('他曾经去过曾家。'), '他曾经去过增家。');
      expect(symbols('他曾家境贫寒'), '他曾家境贫寒');
      expect(symbols('身份暴露了，他只好露了一手。'), '身份暴露了，他只好漏了一手。');
      expect(symbols('他很少露面'), '他很少漏面');
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
      expect(names('Fe3+的溶液呈黄色。'), '铁离子的溶液呈黄色。');
      // A name the sentence already says is not said twice.
      expect(names('醋酸CH3COOH是弱酸。'), '醋酸C H 三 C O O H是弱酸。');
      expect(names('H₃O⁺就是水合氢离子。'), 'H 三 O 正离子就是水合氢离子。');
      expect(names('水的化学式是H2O。'), '水的化学式是H 二 O。');
      expect(names('NH4+和NO3-'), '铵根离子和硝酸根离子');
      // Equations are always spelled: names would make them unreadable.
      expect(names('反应式：2H2+O2=2H2O。'), '反应式：二 H 二 加 O 二 等于 二 H 二 O。');
      // Formulas without a name are left to the voice.
      expect(names('K2Cr2O7是强氧化剂'), '重铬酸钾是强氧化剂');
      expect(names('PbCrO3Xe是什么'), 'PbCrO3Xe是什么');
    });
  });

  group('common formulas by name', () {
    const expected = {
      'NaCl': '氯化钠', 'KCl': '氯化钾', 'MgCl2': '氯化镁', 'CaCl2': '氯化钙',
      'AlCl3': '氯化铝', 'FeCl2': '氯化亚铁', 'FeCl3': '氯化铁', 'CuCl2': '氯化铜',
      'ZnCl2': '氯化锌', 'AgCl': '氯化银', 'BaCl2': '氯化钡', 'NH4Cl': '氯化铵',
      'Hg2Cl2': '氯化亚汞', 'HgCl2': '氯化汞', 'SnCl2': '氯化亚锡', 'SnCl4': '四氯化锡',
      'Na2SO4': '硫酸钠', 'K2SO4': '硫酸钾', 'CuSO4': '硫酸铜', 'FeSO4': '硫酸亚铁',
      'Fe2(SO4)3': '硫酸铁', 'Al2(SO4)3': '硫酸铝', '(NH4)2SO4': '硫酸铵',
      'BaSO4': '硫酸钡', 'ZnSO4': '硫酸锌', 'MgSO4': '硫酸镁', 'NaHSO4': '硫酸氢钠',
      'Na2SO3': '亚硫酸钠', 'NaNO3': '硝酸钠', 'KNO3': '硝酸钾', 'AgNO3': '硝酸银',
      'NH4NO3': '硝酸铵', 'Cu(NO3)2': '硝酸铜', 'NaNO2': '亚硝酸钠',
      'Na2CO3': '碳酸钠', 'K2CO3': '碳酸钾', 'CaCO3': '碳酸钙', 'NaHCO3': '碳酸氢钠',
      'NH4HCO3': '碳酸氢铵', 'Na3PO4': '磷酸钠', 'KH2PO4': '磷酸二氢钾',
      'Na2HPO4': '磷酸氢钠', 'NaOH': '氢氧化钠', 'KOH': '氢氧化钾',
      'Ca(OH)2': '氢氧化钙', 'Mg(OH)2': '氢氧化镁', 'Al(OH)3': '氢氧化铝',
      'Fe(OH)3': '氢氧化铁', 'Fe(OH)2': '氢氧化亚铁', 'Cu(OH)2': '氢氧化铜',
      'Ba(OH)2': '氢氧化钡', 'Na2O': '氧化钠', 'Na2O2': '过氧化钠', 'CaO': '氧化钙',
      'MgO': '氧化镁', 'Al2O3': '氧化铝', 'Fe2O3': '氧化铁', 'FeO': '氧化亚铁',
      'Fe3O4': '四氧化三铁', 'CuO': '氧化铜', 'Cu2O': '氧化亚铜', 'ZnO': '氧化锌',
      'HgO': '氧化汞', 'MnO2': '二氧化锰', 'PbO2': '二氧化铅', 'TiO2': '二氧化钛',
      'Mn2O7': '七氧化二锰', 'Cr2O3': '氧化铬', 'CrO3': '三氧化铬',
      'KMnO4': '高锰酸钾', 'K2MnO4': '锰酸钾', 'KClO3': '氯酸钾', 'NaClO': '次氯酸钠',
      'Ca(ClO)2': '次氯酸钙', 'HClO': '次氯酸', 'HClO4': '高氯酸', 'NaClO2': '亚氯酸钠',
      'K2Cr2O7': '重铬酸钾', 'K2CrO4': '铬酸钾', 'Na2SiO3': '硅酸钠', 'NaAlO2': '偏铝酸钠',
      'Na2S2O3': '硫代硫酸钠', 'CH3COONa': '醋酸钠', 'FeS': '硫化亚铁', 'CuS': '硫化铜',
      'Cu2S': '硫化亚铜', 'H2S': '硫化氢', 'Na2S': '硫化钠', 'NaF': '氟化钠',
      'KBr': '溴化钾', 'NaI': '碘化钠', 'KSCN': '硫氰化钾', 'NaH': '氢化钠',
      'HBr': '溴化氢', 'H2C2O4': '草酸', 'Na2C2O4': '草酸钠', 'KIO3': '碘酸钾',
      'SO2': '二氧化硫', 'SO3': '三氧化硫', 'NO2': '二氧化氮', 'N2O5': '五氧化二氮',
      'N2O': '一氧化二氮', 'N2O4': '四氧化二氮', 'P2O5': '五氧化二磷', 'CCl4': '四氯化碳',
      'CS2': '二硫化碳', 'SiO2': '二氧化硅', 'SiC': '碳化硅', 'PCl3': '三氯化磷',
      'PCl5': '五氯化磷', 'SF6': '六氟化硫', 'ClO2': '二氧化氯', 'Cl2O7': '七氧化二氯',
      'H2SO4': '硫酸', 'HNO3': '硝酸', 'H3PO4': '磷酸', 'H2CO3': '碳酸',
      'H2SO3': '亚硫酸', 'HCl': '氯化氢', 'H2O2': '过氧化氢', 'NH3': '氨气',
      'CH4': '甲烷', 'C2H6': '乙烷', 'C2H4': '乙烯', 'C2H2': '乙炔', 'C6H6': '苯',
      'CH3OH': '甲醇', 'C2H5OH': '乙醇', 'HCHO': '甲醛', 'CH3CHO': '乙醛',
      'HCOOH': '甲酸', 'CH3COOC2H5': '乙酸乙酯', 'C6H5OH': '苯酚',
      'C6H12O6': '葡萄糖', 'C12H22O11': '蔗糖', 'CO(NH2)2': '尿素',
      'NH3·H2O': '一水合氨', 'CuSO4·5H2O': '五水硫酸铜', 'CuSO₄·5H₂O': '五水硫酸铜',
      'Na2CO3·10H2O': '十水碳酸钠', 'CaSO4·2H2O': '二水硫酸钙', 'KAl(SO4)2·12H2O': '十二水硫酸铝钾',
      'O2': '氧气', 'O3': '臭氧', 'Cl2': '氯气', 'N2': '氮气',
      'Cu2+': '铜离子', 'Cu+': '亚铜离子', 'Fe2+': '亚铁离子', 'Al3+': '铝离子',
      'Na+': '钠离子', 'Cl-': '氯离子', 'S2-': '硫离子', 'O2-': '氧离子',
      'CO32-': '碳酸根离子', 'HCO3-': '碳酸氢根离子', 'MnO4-': '高锰酸根离子',
      'MnO42-': '锰酸根离子', 'Cr2O72-': '重铬酸根离子', 'S2O32-': '硫代硫酸根离子',
      'PO43-': '磷酸根离子', 'NH4+': '铵根离子', 'CH3COO-': '醋酸根离子',
      'SCN-': '硫氰根离子', 'Mn²⁺': '锰离子', 'Fe³⁺': '铁离子',
    };
    expected.forEach((formula, name) {
      test(formula, () => expect(names('溶液里加入$formula。'), '溶液里加入$name。'));
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
      'HF天线和KI值',
      'HI，你好，NO不行',
      'PS5游戏机',
      'KFC和CO公司',
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
