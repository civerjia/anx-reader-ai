import 'package:anx_reader/service/library_index/index_terms.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('CJK runs become adjacent pairs; words are lowercased', () {
    expect(queryTermsOf('林特·艾萨克'), ['林特', '艾萨', '萨克']);
    expect(queryTermsOf('Harry Potter 哈利'), ['harry', 'potter', '哈利']);
    expect(queryTermsOf('猫'), ['猫']);
  });

  test('indexed passages keep distinct pairs and drop lone characters', () {
    final terms = indexTermsOf('他说：好。赫萝赫萝').split(' ').toSet();
    expect(terms, containsAll(['他说', '赫萝', '萝赫']));
    expect(terms, isNot(contains('好')));
  });

  test('squashed keeps only letters, digits and CJK', () {
    expect(squashed('林特·艾萨克 Is 1!'), '林特艾萨克is1');
  });
}
