// ignore_for_file: implementation_imports, depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'package:llm_core/llm_core.dart' show DefaultLLMLogger;
import 'package:llm_llamacpp/src/tool_call_parser.dart';
import 'package:llm_llamacpp/src/tool_call_stream_handler.dart';
import 'package:llm_llamacpp/src/tool_calls/tool_call_syntax.dart';

void main() {
  // As MiniCPM5-2B wrote it when asked who 屠呦呦 is.
  const call = '<function name="knowledge_lookup"><param name="query">Tu Youyou</param>'
      '<param name="max_characters">2000</param></function>';

  test('MiniCPM5 XML calls parse, after its reasoning', () {
    final calls = ToolCallParser.parseToolCalls(
        '<think> 我需要先查资料。 </think>\n\n$call');
    expect(calls, hasLength(1));
    expect(calls.single.name, 'knowledge_lookup');
    expect(calls.single.argumentsJson, {'query': 'Tu Youyou', 'max_characters': 2000});
  });

  test('CDATA values are taken as text', () {
    final calls = ToolCallParser.parseToolCalls(
        '<function name="note"><param name="text"><![CDATA[第一行\n<b>第二行</b> & 2000]]></param></function>');
    expect(calls.single.argumentsJson, {'text': '第一行\n<b>第二行</b> & 2000'});
  });

  test('two calls in one reply', () {
    final calls = ToolCallParser.parseToolCalls(
        '$call<function name="bookshelf_lookup"><param name="query">地球</param></function>');
    expect(calls.map((c) => c.name), ['knowledge_lookup', 'bookshelf_lookup']);
  });

  test('a template that writes the tag is detected as this format', () {
    expect(ToolCallFormat.detectFromChatTemplate('... <function name="{{ name }}"> ...'),
        ToolCallFormat.minicpmXml);
  });

  test('streamed in pieces, the call is collected and never shown', () {
    final handler = ToolCallStreamHandler(logger: DefaultLLMLogger('test'), tools: const []);
    final shown = StringBuffer();
    for (final token in ['好的。', '<func', 'tion name="knowledge_lookup"><param name=', '"query">屠呦呦</param></fun', 'ction>']) {
      final result = handler.processToken(token);
      if (result.shouldYield) shown.write(result.content);
    }
    shown.write(handler.finalize(hasTools: true) ?? '');
    expect(shown.toString(), '好的。');
    expect(handler.collectedToolCalls.single.argumentsJson, {'query': '屠呦呦'});
  });
}
