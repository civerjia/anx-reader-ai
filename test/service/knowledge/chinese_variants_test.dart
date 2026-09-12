import 'package:anx_reader/service/knowledge/chinese_variants.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('simplified and traditional characters convert both ways', () {
    expect(toTraditionalChinese('爱'), '愛');
    expect(toSimplifiedChinese('愛'), '爱');
    expect(toSimplifiedChinese(toTraditionalChinese('皑蔼碍爱')), '皑蔼碍爱');
  });

  test('characters without a counterpart, and other scripts, pass through', () {
    expect(toTraditionalChinese('氢 Hydrogen 123'), '${toTraditionalChinese('氢')} Hydrogen 123');
    expect(toSimplifiedChinese('abc'), 'abc');
  });
}
