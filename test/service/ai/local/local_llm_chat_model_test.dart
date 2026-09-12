import 'package:anx_reader/service/ai/local/local_llm_chat_model.dart';
import 'package:anx_reader/service/ai/local/local_llm_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:langchain_core/chat_models.dart';
import 'package:langchain_core/language_models.dart';
import 'package:langchain_core/prompts.dart';
import 'package:langchain_core/tools.dart';
import 'package:llm_llamacpp/llm_llamacpp.dart'
    show LLMMessage, LLMRole, LLMTool, LLMToolCall;

/// Records what the adapter hands the engine and replays canned events.
class _FakeEngine extends LocalLlmEngine {
  _FakeEngine(this.events) : super.fake();

  _FakeEngine.text(List<String> pieces)
      : this([for (final piece in pieces) LocalLlmText(piece)]);

  final List<LocalLlmEvent> events;
  List<LLMMessage> seenMessages = const [];
  List<LLMTool> seenTools = const [];
  String? seenModel;
  int? seenMaxTokens;

  @override
  Stream<LocalLlmEvent> stream({
    required String modelName,
    required List<LLMMessage> messages,
    List<LLMTool> tools = const [],
    int maxTokens = 640,
    double temperature = 0.7,
  }) {
    seenModel = modelName;
    seenMessages = messages;
    seenTools = tools;
    seenMaxTokens = maxTokens;
    return Stream.fromIterable(events);
  }
}

void main() {
  group('streaming', () {
    test('each piece becomes a streaming chunk', () async {
      final engine = _FakeEngine.text(['格物', '致知', '出自《大学》。']);
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
        engine: _FakeEngine.text(['一', '句', '话']),
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
      final engine = _FakeEngine.text(['ok']);
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
      final engine = _FakeEngine.text(['ok']);
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
      final engine = _FakeEngine.text(['ok']);
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
      final engine = _FakeEngine.text(['ok']);
      final model = LocalLlmChatModel(
        modelName: 'm.gguf',
        engine: engine,
        defaultOptions: const LocalLlmChatModelOptions(maxTokens: 100),
      );

      await model.invoke(PromptValue.chat([ChatMessage.humanText('问')]));

      expect(engine.seenMaxTokens, 100);
    });
  });

  group('tool calls', () {
    const lookup = ToolSpec(
      name: 'bookshelf_lookup',
      description: 'Find books on the shelf.',
      inputJsonSchema: {
        'type': 'object',
        'properties': {
          'query': {'type': 'string'},
        },
      },
    );

    test('offered tools reach the engine with their schema intact', () async {
      final engine = _FakeEngine.text(['ok']);
      final model = LocalLlmChatModel(modelName: 'm.gguf', engine: engine);

      await model.invoke(
        PromptValue.chat([ChatMessage.humanText('我书架上有什么')]),
        options: const LocalLlmChatModelOptions(tools: [lookup]),
      );

      expect(engine.seenTools, hasLength(1));
      final function =
          engine.seenTools.single.toJson['function'] as Map<String, dynamic>;
      expect(function['name'], 'bookshelf_lookup');
      expect(function['parameters'], lookup.inputJsonSchema);
    });

    test('a call from the model becomes a langchain tool call', () async {
      final engine = _FakeEngine([
        LocalLlmToolCalls([
          LLMToolCall(
            id: '',
            name: 'bookshelf_lookup',
            arguments: '{"query": "地球"}',
          ),
        ]),
      ]);
      final model = LocalLlmChatModel(modelName: 'm.gguf', engine: engine);

      final result = await model.invoke(
        PromptValue.chat([ChatMessage.humanText('找地球的书')]),
        options: const LocalLlmChatModelOptions(tools: [lookup]),
      );

      final call = result.output.toolCalls.single;
      expect(call.name, 'bookshelf_lookup');
      expect(call.arguments, {'query': '地球'});
      expect(call.id, isNotEmpty);
      expect(result.finishReason, FinishReason.toolCalls);
    });

    test('two calls in one turn keep distinct ids and do not merge', () async {
      final engine = _FakeEngine([
        LocalLlmToolCalls([
          LLMToolCall(id: '', name: 'a', arguments: '{}'),
          LLMToolCall(id: '', name: 'b', arguments: '{}'),
        ]),
      ]);
      final model = LocalLlmChatModel(modelName: 'm.gguf', engine: engine);

      final result = await model.invoke(
        PromptValue.chat([ChatMessage.humanText('x')]),
      );

      final calls = result.output.toolCalls;
      expect(calls.map((c) => c.name), ['a', 'b']);
      expect(calls[0].id, isNot(calls[1].id));
    });

    test('malformed arguments are kept raw rather than thrown', () async {
      final engine = _FakeEngine([
        LocalLlmToolCalls([
          LLMToolCall(id: '', name: 'a', arguments: '{not json'),
        ]),
      ]);
      final model = LocalLlmChatModel(modelName: 'm.gguf', engine: engine);

      final result = await model.invoke(
        PromptValue.chat([ChatMessage.humanText('x')]),
      );

      final call = result.output.toolCalls.single;
      expect(call.arguments, isEmpty);
      expect(call.argumentsRaw, '{not json');
    });
  });

  group('replaying a tool round trip', () {
    test('the call is written back as <tool_call> markup', () {
      final messages = LocalLlmChatModel.toLlmMessages([
        ChatMessage.humanText('我读了什么'),
        ChatMessage.ai(
          '',
          toolCalls: const [
            AIChatMessageToolCall(
              id: 'local-call-1',
              name: 'reading_history',
              argumentsRaw: '{"limit": 5}',
              arguments: {'limit': 5},
            ),
          ],
        ),
        ChatMessage.tool(toolCallId: 'local-call-1', content: '[]'),
      ]);

      expect(messages.map((m) => m.role),
          [LLMRole.user, LLMRole.assistant, LLMRole.tool]);
      expect(messages[1].content, contains('<tool_call>'));
      expect(messages[1].content, contains('"name":"reading_history"'));
      expect(messages[1].content, contains('"limit":5'));
      expect(messages[2].content, '[]');
      // llm_llamacpp rejects a tool message without one ("Tool message must
      // have toolCallId") before generation even starts.
      expect(messages[2].toolCallId, 'local-call-1');
    });

    test('an empty tool result is still a turn', () {
      final messages = LocalLlmChatModel.toLlmMessages([
        ChatMessage.tool(toolCallId: 'x', content: ''),
      ]);
      expect(messages.single.role, LLMRole.tool);
      expect(messages.single.content, isNotEmpty);
    });
  });

  group('system turns', () {
    test('several system messages become one, placed first', () {
      final messages = LocalLlmChatModel.toLlmMessages([
        ChatMessage.system('你是阅读助手。'),
        ChatMessage.humanText('第一个问题'),
        ChatMessage.system('[Shelf] 3 books'),
        ChatMessage.humanText('第二个问题'),
      ]);

      expect(messages.map((m) => m.role),
          [LLMRole.system, LLMRole.user, LLMRole.user]);
      expect(messages.first.content, contains('你是阅读助手。'));
      expect(messages.first.content, contains('[Shelf] 3 books'));
      expect(
        messages.first.content!.indexOf('你是阅读助手。'),
        lessThan(messages.first.content!.indexOf('[Shelf]')),
      );
      expect(messages[2].content, '第二个问题');
    });

    test('no system message means none is invented', () {
      final messages = LocalLlmChatModel.toLlmMessages([
        ChatMessage.humanText('问'),
      ]);
      expect(messages.single.role, LLMRole.user);
    });
  });

  group('tool results on a phone-sized context', () {
    test('a short result passes through untouched', () {
      expect(LocalLlmChatModel.clipToolResult('[]'), '[]');
    });

    test('a whole chapter is cut to the limit and says so', () {
      final chapter = '字' * 30000;
      final clipped = LocalLlmChatModel.clipToolResult(chapter);
      expect(
        clipped.length,
        lessThan(LocalLlmChatModel.toolResultCharacterLimit + 80),
      );
      expect(clipped, contains('truncated'));
      expect(clipped, contains('30000'));
    });

    test('replay applies the limit to tool turns', () {
      final messages = LocalLlmChatModel.toLlmMessages([
        ChatMessage.tool(toolCallId: 'c', content: 'x' * 20000),
      ]);
      expect(messages.single.content!.length,
          lessThan(LocalLlmChatModel.toolResultCharacterLimit + 80));
    });
  });
}