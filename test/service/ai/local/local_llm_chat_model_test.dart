import 'package:anx_reader/service/ai/local/local_llm_chat_model.dart';
import 'package:anx_reader/service/ai/local/local_llm_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langchain_core/chat_models.dart';
import 'package:langchain_core/prompts.dart';
import 'package:llm_llamacpp/llm_llamacpp.dart' show LLMMessage, LLMRole;

/// Records what the adapter hands the engine and replays a canned reply.
class _FakeEngine extends LocalLlmEngine {
  _FakeEngine(this.pieces) : super.fake();

  final List<String> pieces;
  List<LLMMessage> seenMessages = const [];
  String? seenModel;
  int? seenMaxTokens;

  @override
  Stream<String> stream({
    required String modelName,
    required List<LLMMessage> messages,
    int maxTokens = 640,
    double temperature = 0.7,
  }) {
    seenModel = modelName;
    seenMessages = messages;
    seenMaxTokens = maxTokens;
    return Stream.fromIterable(pieces);
  }
}

void main() {
  group('streaming', () {
    test('each piece becomes a streaming chunk', () async {
      final engine = _FakeEngine(['格物', '致知', '出自《大学》。']);
      final model = LocalLlmChatModel(
        modelName: 'Qwen3.5-2B.gguf',
        engine: engine,
      );

      final results = await model
          .stream(PromptValue.chat([ChatMessage.humanText('问')]))
          .toList();

      expect(results.map((r) => r.output.content).toList(),
          ['格物', '致知', '出自《大学》。']);
      expect(results.every((r) => r.streaming), isTrue);
      expect(results.first.metadata['model'], 'Qwen3.5-2B.gguf');
      expect(engine.seenModel, 'Qwen3.5-2B.gguf');
    });

    test('invoke joins the pieces into one reply', () async {
      final model = LocalLlmChatModel(
        modelName: 'm.gguf',
        engine: _FakeEngine(['一', '句', '话']),
      );

      final result = await model.invoke(
        PromptValue.chat([ChatMessage.humanText('问')]),
      );

      expect(result.output.content, '一句话');
      expect(result.streaming, isFalse);
    });
  });

  group('message conversion', () {
    test('system, human and ai roles survive the crossing', () async {
      final engine = _FakeEngine(['ok']);
      final model = LocalLlmChatModel(modelName: 'm.gguf', engine: engine);

      await model.invoke(PromptValue.chat([
        ChatMessage.system('你是阅读助手。'),
        ChatMessage.humanText('第一个问题'),
        ChatMessage.ai('第一个回答'),
        ChatMessage.humanText('追问'),
      ]));

      expect(
        engine.seenMessages.map((m) => m.role).toList(),
        [LLMRole.system, LLMRole.user, LLMRole.assistant, LLMRole.user],
      );
      expect(engine.seenMessages.last.content, '追问');
    });

    test('empty messages are dropped rather than sent as blanks', () async {
      final engine = _FakeEngine(['ok']);
      final model = LocalLlmChatModel(modelName: 'm.gguf', engine: engine);

      await model.invoke(PromptValue.chat([
        ChatMessage.system(''),
        ChatMessage.humanText('只有这一条'),
      ]));

      expect(engine.seenMessages, hasLength(1));
      expect(engine.seenMessages.single.role, LLMRole.user);
    });
  });

  group('options', () {
    test('the per-call token budget wins over the default', () async {
      final engine = _FakeEngine(['ok']);
      final model = LocalLlmChatModel(
        modelName: 'm.gguf',
        engine: engine,
        defaultOptions: const LocalLlmChatModelOptions(maxTokens: 100),
      );

      await model.invoke(
        PromptValue.chat([ChatMessage.humanText('问')]),
        options: const LocalLlmChatModelOptions(maxTokens: 42),
      );

      expect(engine.seenMaxTokens, 42);
    });

    test('the default applies when a call carries no options', () async {
      final engine = _FakeEngine(['ok']);
      final model = LocalLlmChatModel(
        modelName: 'm.gguf',
        engine: engine,
        defaultOptions: const LocalLlmChatModelOptions(maxTokens: 100),
      );

      await model.invoke(PromptValue.chat([ChatMessage.humanText('问')]));

      expect(engine.seenMaxTokens, 100);
    });
  });
}
