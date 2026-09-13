import 'package:anx_reader/service/ai/local/empty_think_filter.dart';
import 'package:flutter_test/flutter_test.dart';

({String reasoning, String answer}) route(List<String> pieces) {
  final router = LeadingThinkRouter();
  var reasoning = '';
  var answer = '';
  for (final part in [...pieces.map(router.add), router.close()]) {
    reasoning += part.reasoning;
    answer += part.answer;
  }
  return (reasoning: reasoning, answer: answer);
}

void main() {
  group('thinking not asked for', () {
    test('an empty block is dropped however it is split', () {
      expect(route(['<think>\n\n</think>\n\n答案']), (reasoning: '', answer: '答案'));
      expect(route(['<think>', '\n\n', '</think>', '\n\n', '答案是', '一']),
          (reasoning: '', answer: '答案是一'));
      expect(route(['<th', 'ink>', '\n', '</thi', 'nk>', '答案']), (reasoning: '', answer: '答案'));
      expect(route([' <think> </think> ', '<tool_call>{}</tool_call>']),
          (reasoning: '', answer: '<tool_call>{}</tool_call>'));
    });

    test('reasoning the model starts on its own goes to reasoning', () {
      // As logged on the phone: reasoning, then a tool call.
      expect(
          route(['<think>\n用户问的是读音。\n', '</think>\n\n', '<tool_call>{}</tool_call>']),
          (reasoning: '用户问的是读音。\n', answer: '<tool_call>{}</tool_call>'));
    });

    test('a reply that does not open with <think> is untouched', () {
      expect(route(['答案', '<think></think>']), (reasoning: '', answer: '答案<think></think>'));
      expect(route(['<t', 'able>']), (reasoning: '', answer: '<table>'));
      expect(route(['<thi']), (reasoning: '', answer: '<thi'));
    });
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
