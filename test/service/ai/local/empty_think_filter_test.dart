import 'package:anx_reader/service/ai/local/empty_think_filter.dart';
import 'package:flutter_test/flutter_test.dart';

String run(List<String> pieces) {
  final filter = EmptyThinkFilter();
  return pieces.map(filter.add).join() + filter.close();
}

void main() {
  test('drops the empty block however it is split', () {
    expect(run(['<think>\n\n</think>\n\n答案']), '答案');
    expect(run(['<think>', '\n\n', '</think>', '\n\n', '答案是', '一']), '答案是一');
    expect(run(['<th', 'ink>', '\n', '</thi', 'nk>', '答案']), '答案');
    expect(run([' <think> </think> ', '<tool_call>{}</tool_call>']), '<tool_call>{}</tool_call>');
  });

  test('passes everything else through', () {
    expect(run(['答案', '<think></think>']), '答案<think></think>');
    expect(run(['<think>想一想</think>答案']), '<think>想一想</think>答案');
    expect(run(['<t', 'able>']), '<table>');
    expect(run(['<think>']), '<think>');
    expect(run(['<think>\n</think>']), '');
  });

  group('thinking on', () {
    ({String reasoning, String answer}) split(List<String> pieces) {
      final splitter = ThinkSplitter();
      var reasoning = '';
      var answer = '';
      for (final piece in [...pieces.map(splitter.add), splitter.close()]) {
        reasoning += piece.reasoning;
        answer += piece.answer;
      }
      return (reasoning: reasoning, answer: answer);
    }

    test('reasoning up to </think>, the answer after it', () {
      expect(split(['条目写的是 Ēpáng。\n</think>\n\n读 ē。']),
          (reasoning: '条目写的是 Ēpáng。\n', answer: '读 ē。'));
    });

    test('a closing tag split across pieces', () {
      expect(split(['想', '一想</th', 'ink>', '\n', '\n答', '案']),
          (reasoning: '想一想', answer: '答案'));
    });

    test('a look-alike is kept as reasoning', () {
      expect(split(['a </thin', 'g> b']), (reasoning: 'a </thing> b', answer: ''));
    });

    test('cut off before </think>, everything is reasoning', () {
      expect(split(['想了很久', '</thi']), (reasoning: '想了很久</thi', answer: ''));
    });
  });
}
