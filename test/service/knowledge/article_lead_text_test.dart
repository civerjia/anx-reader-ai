import 'package:anx_reader/service/knowledge/zim_archive.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('skips infobox tables and coordinate lines', () {
    const html = '''
<body><div class="mw-parser-output">
<p><span class="geo">黄河源 34°29′31″N 96°20′25″E\ufeff / \ufeff34.49194°N 96.34028°E\ufeff / 34.49194; 96.34028</span></p>
<table class="infobox"><tr><td><table><tr><td><p>东盟（深灰色）&nbsp; —&nbsp; [圖例放大]</p></td></tr></table></td></tr></table>
<p>19°45′N 96°6′E / 19.750°N 96.100°E / 19.750; 96.100</p>
<p><b>黄河</b>是中国的第二长河，仅次于长江，发源于青海省。<sup>[1]</sup></p>
<p>黄河中游流经黄土高原，位于北纬35°附近的河段含沙量最高。</p>
</div></body>''';
    expect(articleLeadText(html),
        '黄河是中国的第二长河，仅次于长江，发源于青海省。\n黄河中游流经黄土高原，位于北纬35°附近的河段含沙量最高。');
  });
}
