import 'package:anx_reader/enums/ai_prompts.dart';
import 'package:anx_reader/service/ai/local/local_llm_budget.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langchain_core/chat_models.dart';

void main() {
  group('answer budgets differ by what is being asked', () {
    test('a dictionary lookup is short', () {
      expect(localAnswerBudget(AiPrompts.translate), 512);
    });

    test('a mind map gets the most room', () {
      final mindmap = localAnswerBudget(AiPrompts.mindmap);
      expect(mindmap, greaterThan(localAnswerBudget(AiPrompts.translate)));
      expect(
        mindmap,
        greaterThan(localAnswerBudget(AiPrompts.summaryTheChapter)),
      );
    });

    test('a recap is shorter than a full chapter summary', () {
      expect(
        localAnswerBudget(AiPrompts.summaryThePreviousContent),
        lessThan(localAnswerBudget(AiPrompts.summaryTheChapter)),
      );
    });
  });

  group('translation is sized from its input', () {
    test('a long passage gets more room than a short one', () {
      final short =
          localAnswerBudget(AiPrompts.fullTextTranslate, promptTokens: 400);
      final long =
          localAnswerBudget(AiPrompts.fullTextTranslate, promptTokens: 2000);
      expect(long, greaterThan(short));
    });

    test('at least as much room as the input took', () {
      const promptTokens = 1000;
      expect(
        localAnswerBudget(AiPrompts.fullTextTranslate,
            promptTokens: promptTokens),
        greaterThanOrEqualTo(promptTokens),
      );
    });

    test('a tiny input still gets a usable floor', () {
      expect(
        localAnswerBudget(AiPrompts.fullTextTranslate, promptTokens: 10),
        512,
      );
    });

    test('a whole chapter is capped rather than unbounded', () {
      expect(
        localAnswerBudget(AiPrompts.fullTextTranslate, promptTokens: 100000),
        4096,
      );
    });
  });

  group('token estimation', () {
    test('counts CJK at about one token per character', () {
      final tokens = estimateTokens([ChatMessage.humanText('火山喷发')]);
      expect(tokens, 4);
    });

    test('counts Latin script at about four characters per token', () {
      // 16 characters -> 4 tokens.
      final tokens = estimateTokens([ChatMessage.humanText('abcdefghijklmnop')]);
      expect(tokens, 4);
    });

    test('adds up across messages', () {
      final tokens = estimateTokens([
        ChatMessage.system('你是助手'),
        ChatMessage.humanText('火山'),
      ]);
      expect(tokens, 6);
    });
  });
}
