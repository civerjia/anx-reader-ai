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
}
