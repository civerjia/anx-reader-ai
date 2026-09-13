import 'dart:convert';

import 'package:anx_reader/service/ai/local/tool_argument_repair.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llm_llamacpp/llm_llamacpp.dart';

void main() {
  const asked = '林特·艾萨克在书中是什么角色';

  test('a mis-copied name is put back as the user typed it', () {
    expect(repairAgainst('林特·艾克撒克', asked), '林特·艾萨克');
    expect(repairAgainst('林特艾萨克', asked), '林特·艾萨克');
  });

  test('words the user typed, or unrelated ones, are left alone', () {
    expect(repairAgainst('艾萨克', asked), '艾萨克');
    expect(repairAgainst('林特·艾萨克', asked), '林特·艾萨克');
    expect(repairAgainst('魔王的部下', asked), '魔王的部下');
    expect(repairAgainst('Lint Isaac', asked), 'Lint Isaac');
    expect(repairAgainst('book', 'look at this'), 'book');
  });

  test('tool calls keep other arguments and ids', () {
    final calls = repairToolCalls([
      LLMToolCall(
          id: 'c1',
          name: 'book_content_search',
          arguments: jsonEncode({'bookId': 15, 'keyword': '林特·艾克撒克'})),
    ], asked);
    expect(calls.single.id, 'c1');
    expect(jsonDecode(calls.single.arguments),
        {'bookId': 15, 'keyword': '林特·艾萨克'});
  });
}
