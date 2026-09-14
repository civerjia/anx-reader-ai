import 'package:flutter_test/flutter_test.dart';
import 'package:llm_llamacpp/src/isolate_messages.dart';
import 'package:llm_llamacpp/src/spark_chat_template.dart';
import 'package:llm_llamacpp/src/tool_call_parser.dart';
import 'package:llm_llamacpp/src/tool_calls/tool_call_syntax.dart';

void main() {
  const bos = '<｜start▁of▁sentence｜>';
  const eos = '<｜end▁of▁sentence｜>';

  test('renders turns as the Spark template does', () {
    final prompt = renderSparkPrompt(const [
      IsolateMessage(role: 'system', content: 'Be brief.'),
      IsolateMessage(role: 'user', content: '赫萝是谁'),
      IsolateMessage(
          role: 'assistant',
          content: '<tool_call>\n{"name": "book_content_search", '
              '"arguments": {"bookId": 15, "keyword": "赫萝"}}\n</tool_call>'),
      IsolateMessage(role: 'tool', content: '{"a":1}'),
      IsolateMessage(role: 'tool', content: '{"b":2}'),
      IsolateMessage(role: 'user', content: '然后呢'),
    ]);
    expect(
      prompt,
      '$bos<|System|>\nyou are a helpful assistant.\n\nBe brief.$eos'
      '$bos<|User|>赫萝是谁$eos'
      '$bos<|Bot|></think><tool_call>book_content_search'
      '<arg_key>bookId</arg_key><arg_value>15</arg_value>'
      '<arg_key>keyword</arg_key><arg_value>赫萝</arg_value></tool_call>$eos'
      '$bos<|Tool|><tool_response>{"a":1}</tool_response>'
      '<tool_response>{"b":2}</tool_response>$eos'
      '$bos<|User|>然后呢$eos'
      '$bos<|Bot|>',
    );
  });

  test('recognises the template by its markers', () {
    expect(isSparkChatTemplate("{{- '$bos<|System|>' }} ... '<|Bot|>'"), isTrue);
    expect(isSparkChatTemplate('<|im_start|>assistant'), isFalse);
    expect(
        ToolCallFormat.detectFromChatTemplate(
            "{{- '<tool_call>' + name }}{{- '<arg_key>' ~ k }}"),
        ToolCallFormat.sparkArgs);
  });

  test('parses Spark tool calls, strings as text and others as JSON', () {
    final calls = ToolCallParser.parseToolCalls(
      '</think>查一下。<tool_call>book_content_search<arg_key>bookId</arg_key>'
      '<arg_value>15</arg_value><arg_key>keyword</arg_key>'
      '<arg_value>林特·艾萨克</arg_value></tool_call>',
      format: ToolCallFormat.sparkArgs,
    );
    expect(calls.single.name, 'book_content_search');
    expect(calls.single.argumentsJson, {'bookId': 15, 'keyword': '林特·艾萨克'});
  });
}
