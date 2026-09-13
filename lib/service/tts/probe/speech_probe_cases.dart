import 'package:anx_reader/service/tts/probe/speech_probe.dart';
import 'package:anx_reader/service/tts/text/chemistry.dart';
import 'package:anx_reader/service/tts/text/speech_text.dart';

/// Sentences that exercise what a text-to-speech front end has to decide
/// before any sound is made: how to say numbers, symbols and formulas, and
/// which reading a polyphonic character takes. Chinese only: the reader's
/// narration problems were heard in Chinese books.
final speechProbeGroups = [..._heard, _rewritten()];

/// The sentences the system voice misread, rewritten the way narration now
/// rewrites them, in both formula readings.
ProbeGroup _rewritten() {
  const misread = {'n18', 'n19', 'c03', 'c04', 'c05', 'c06', 'c07', 'c08', 'c09', 'c10', 'c12'};
  final cases = <ProbeCase>[];
  for (final probe in _heard.expand((g) => g.cases)) {
    if (!misread.contains(probe.id)) continue;
    final spelled = SpeechText.normalize(probe.text);
    final named = SpeechText.normalize(probe.text, formulas: FormulaReading.names);
    cases.add(ProbeCase('r-${probe.id}', spelled, '字母读法 · 原句 ${probe.text}'));
    if (named != spelled) {
      cases.add(ProbeCase('r-${probe.id}-name', named, '名称读法 · 原句 ${probe.text}'));
    }
    if (probe.id == 'c12') {
      cases.add(ProbeCase('r-c12-ipa', spelled, '字母读法，H 标英文读音，防止读成"小时"',
          marks: [for (var k = 0; k < 3; k++) ProbeMark('H', 'eɪtʃ', occurrence: k)]));
    }
  }
  return ProbeGroup('改写效果', '上面读错的句子改写后再读。字母读法和名称读法你更想要哪种？', cases);
}

const _heard = [
  ProbeGroup('数字', '年份逐位读、数量按数值读、各种符号和单位。', [
    ProbeCase('n01', '这本书出版于2024年。', '二零二四年'),
    ProbeCase('n02', '仓库里有2024箱货。', '两千零二十四箱'),
    ProbeCase('n03', '圆周率约等于3.14159。', '三点一四一五九'),
    ProbeCase('n04', '只剩下1/3的人。', '三分之一'),
    ProbeCase('n05', '销量增长了50%。', '百分之五十'),
    ProbeCase('n06', '明天最低气温-5℃。', '零下五摄氏度'),
    ProbeCase('n07', '请拨打13812345678。', '逐位读，1 读"幺"'),
    ProbeCase('n08', '请升级到v2.1.3版本。', 'V 二点一点三'),
    ProbeCase('n09', '会议定在下午3:30。', '三点三十'),
    ProbeCase('n10', '请看第3章第12节。', '第三章第十二节'),
    ProbeCase('n11', '机器重2.5kg，时速120km/h。', '二点五千克，一百二十千米每小时'),
    ProbeCase('n12', '人口达到1,234,567人。', '一百二十三万四千五百六十七'),
    ProbeCase('n13', '大约需要3-5天。', '三到五天'),
    ProbeCase('n14', '售价¥128.50，约合\$18。', '一百二十八点五元，十八美元'),
    ProbeCase('n15', '日期是2024-09-12。', '二零二四年九月十二日'),
    ProbeCase('n16', '公元前221年秦统一六国。', '公元前二二一年'),
    ProbeCase('n17', '那是上世纪90年代。', '九十年代'),
    ProbeCase('n18', '浓度为1×10⁻³ mol/L。', '一乘十的负三次方摩尔每升'),
    ProbeCase('n19', '他在比赛中排名No.1。', '第一'),
    ProbeCase('n20', 'iPhone 16 Pro用的是A18芯片。', '十六，A 十八'),
  ]),
  ProbeGroup('化学', '能读出名称最好；读成"H 三 O 正"也算能听懂。', [
    ProbeCase('c01', '水的化学式是H2O。', 'H 二 O'),
    ProbeCase('c02', 'H₂O在100℃沸腾。', 'H 二 O，一百摄氏度'),
    ProbeCase('c03', '酸溶液中存在H3O+。', '水合氢离子，或 H 三 O 正'),
    ProbeCase('c04', 'H₃O⁺就是水合氢离子。', '同上'),
    ProbeCase('c05', 'CO2是一种温室气体。', 'C O 二 / 二氧化碳'),
    ProbeCase('c06', 'NaCl易溶于水。', '氯化钠'),
    ProbeCase('c07', '溶液中的OH-浓度升高。', '氢氧根'),
    ProbeCase('c08', 'SO₄²⁻与Ba²⁺生成沉淀。', '硫酸根，钡离子'),
    ProbeCase('c09', 'Fe3+的溶液呈黄色。', '三价铁离子'),
    ProbeCase('c10', '醋酸CH3COOH是弱酸。', 'C H 三 C O O H'),
    ProbeCase('c11', 'pH=7时溶液呈中性。', 'P H 等于七'),
    ProbeCase('c12', '反应式：2H2+O2=2H2O。', '二 H 二 加 O 二 生成 二 H 二 O'),
  ]),
  ProbeGroup('多音字', '按词语上下文，系统语音自己能读对多少。', [
    ProbeCase('p01', '他还没还钱。', 'hái … huán'),
    ProbeCase('p02', '银行门口有人在行走。', 'háng … xíng'),
    ProbeCase('p03', '孩子长大了，头发也长了。', 'zhǎng … cháng'),
    ProbeCase('p04', '重新称一下重量。', 'chóng … zhòng'),
    ProbeCase('p05', '音乐让人快乐。', 'yuè … lè'),
    ProbeCase('p06', '他在调查空调故障。', 'diào … tiáo'),
    ProbeCase('p07', '出差的人差不多到齐了，队伍参差不齐。', 'chāi … chà … cī'),
    ProbeCase('p08', '这本传记讲的是一个传说。', 'zhuàn … chuán'),
    ProbeCase('p09', '朝阳照着古代的朝廷。', 'zhāo … cháo'),
    ProbeCase('p10', '睡觉的时候觉得冷。', 'jiào … jué'),
    ProbeCase('p11', '他着急地看着着火的房子。', 'zháo … zhe … zháo'),
    ProbeCase('p12', '这里东西便宜，交通方便。', 'pián … biàn'),
    ProbeCase('p13', '数一数数学作业有几道题。', 'shǔ … shù'),
    ProbeCase('p14', '他在公司当会计，经常开会。', 'kuài … huì'),
    ProbeCase('p15', '他流了很多血，伤口血淋淋的。', 'xuè … xiě'),
    ProbeCase('p16', '仇先生从不记仇。', 'qiú … chóu'),
    ProbeCase('p17', '匈奴的单于不在这个单位。', 'chán … dān'),
    ProbeCase('p18', '两人一模一样，都是劳动模范。', 'mú … mó'),
    ProbeCase('p19', '身份暴露了，他只好露了一手。', 'lù … lòu'),
    ProbeCase('p20', '他曾经去过曾家。', 'céng … zēng'),
    ProbeCase('p21', '给予帮助，把书给他。', 'jǐ … gěi'),
    ProbeCase('p22', '先处理好这个住处。', 'chǔ … chù'),
    ProbeCase('p23', '薄饼很薄，上面放了薄荷。', 'báo … báo … bò'),
    ProbeCase('p24', '一个不是，一起不对。', '变调：yí gè bú shì，yì qǐ bú duì'),
  ]),
  ProbeGroup(
    '读音标注',
    '同一句用不同写法指定读音。先听"强制读错"两句：如果读音变了，说明标注有效。',
    [
      ProbeCase('i01', '银行', '原样：yín háng'),
      ProbeCase('i02', '银行', '强制读错成 yín xíng（IPA）',
          marks: [ProbeMark('行', 'ɕiŋ˧˥')]),
      ProbeCase('i03', '音乐', '强制读错成 yīn lè（IPA）',
          marks: [ProbeMark('乐', 'lɤ˥˩')]),
      ProbeCase('i04', '银行', '强制读错成 yín xíng（拼音 xíng）',
          marks: [ProbeMark('行', 'xíng')]),
      ProbeCase('i05', '他还钱。', '原样，应读 huán'),
      ProbeCase('i06', '他还钱。', 'IPA 标 huán',
          marks: [ProbeMark('还', 'xwan˧˥')]),
      ProbeCase('i07', '他还钱。', '拼音 huán', marks: [ProbeMark('还', 'huán')]),
      ProbeCase('i08', '他还钱。', '拼音 huan2', marks: [ProbeMark('还', 'huan2')]),
      ProbeCase('i09', '他环钱。', '同音字替换，应听成 huán'),
      ProbeCase('i10', '仇先生来了。', '原样，应读 qiú'),
      ProbeCase('i11', '仇先生来了。', 'IPA 标 qiú',
          marks: [ProbeMark('仇', 'tɕʰjoʊ˧˥')]),
      ProbeCase('i12', '球先生来了。', '同音字替换，应听成 qiú'),
      ProbeCase('i13', '伤口血淋淋的。', '原样，应读 xiě'),
      ProbeCase('i14', '伤口血淋淋的。', 'IPA 标 xiě',
          marks: [ProbeMark('血', 'ɕjɛ˨˩˦')]),
      ProbeCase('i15', '伤口写淋淋的。', '同音字替换，应听成 xiě'),
    ],
  ),
];
