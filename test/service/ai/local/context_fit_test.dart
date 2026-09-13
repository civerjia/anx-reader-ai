import 'package:anx_reader/service/ai/local/context_fit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llm_llamacpp/llm_llamacpp.dart' show LLMMessage, LLMRole;

void main() {
  LLMMessage m(LLMRole role, String text) => LLMMessage(role: role, content: text);

  test('a conversation that fits is untouched', () {
    final messages = [m(LLMRole.system, 'sys'), m(LLMRole.user, '赫萝是谁')];
    final fitted = fitToContext(messages, 1000);
    expect(fitted.messages, same(messages));
  });

  test('a chapter left in an earlier turn is shortened first', () {
    final chapter = '字' * 20000;
    final fitted = fitToContext([
      m(LLMRole.system, 'sys'),
      m(LLMRole.user, '总结这一章'),
      m(LLMRole.assistant, chapter),
      m(LLMRole.user, '赫萝是谁'),
    ], 4000);
    expect(fitted.clipped, 1);
    expect(fitted.dropped, 0);
    expect(fitted.messages.last.content, '赫萝是谁');
    expect(fitted.messages[2].content!.length, lessThan(1300));
  });

  test('oldest turns go when shortening is not enough; system and latest stay',
      () {
    final fitted = fitToContext([
      m(LLMRole.system, 'sys'),
      for (var i = 0; i < 20; i++) ...[
        m(LLMRole.user, '问题$i${'问' * 1000}'),
        m(LLMRole.assistant, '回答$i${'答' * 1000}'),
      ],
      m(LLMRole.user, '赫萝是谁'),
    ], 3000);
    expect(fitted.dropped, greaterThan(0));
    expect(fitted.messages.first.role, LLMRole.system);
    expect(fitted.messages.last.content, '赫萝是谁');
    final size = fitted.messages
        .fold(0, (s, x) => s + roughTokens(x.content ?? '') + 8);
    expect(size, lessThanOrEqualTo(3000));
  });
}
