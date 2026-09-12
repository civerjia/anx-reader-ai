import 'package:anx_reader/service/ai/local/local_llm_engine.dart';
import 'package:langchain_core/chat_models.dart';
import 'package:langchain_core/language_models.dart';
import 'package:langchain_core/prompts.dart';
import 'package:langchain_core/tools.dart';
import 'package:llm_llamacpp/llm_llamacpp.dart' show LLMMessage, LLMRole;

/// Options for [LocalLlmChatModel].
class LocalLlmChatModelOptions extends ChatModelOptions {
  const LocalLlmChatModelOptions({
    super.model,
    super.tools,
    super.toolChoice,
    super.concurrencyLimit,
    this.maxTokens = 640,
    this.temperature = 0.7,
  });

  /// Kept modest on purpose: at the 20 tok/s a phone manages, 640 tokens is
  /// already half a minute of waiting.
  final int maxTokens;

  final double temperature;

  @override
  LocalLlmChatModelOptions copyWith({
    final String? model,
    final List<ToolSpec>? tools,
    final ChatToolChoice? toolChoice,
    final int? concurrencyLimit,
    final int? maxTokens,
    final double? temperature,
  }) {
    return LocalLlmChatModelOptions(
      model: model ?? this.model,
      tools: tools ?? this.tools,
      toolChoice: toolChoice ?? this.toolChoice,
      concurrencyLimit: concurrencyLimit ?? super.concurrencyLimit,
      maxTokens: maxTokens ?? this.maxTokens,
      temperature: temperature ?? this.temperature,
    );
  }
}

/// A langchain chat model backed by llama.cpp running on this device.
///
/// Implementing the langchain interface rather than a separate code path is
/// what makes every existing feature — the excerpt menu, chapter summaries,
/// the chat page — work against a local model without touching any of them.
class LocalLlmChatModel extends BaseChatModel<LocalLlmChatModelOptions> {
  LocalLlmChatModel({
    required this.modelName,
    final LocalLlmEngine? engine,
    super.defaultOptions = const LocalLlmChatModelOptions(),
  }) : engine = engine ?? LocalLlmEngine.instance;

  /// The engine to generate through; injectable so a test can exercise this
  /// adapter without loading two gigabytes of weights.
  final LocalLlmEngine engine;

  /// File name of the GGUF weights, resolved to a path at generation time.
  final String modelName;

  @override
  String get modelType => 'local-llama-cpp';

  @override
  Future<ChatResult> invoke(
    final PromptValue input, {
    final LocalLlmChatModelOptions? options,
  }) async {
    final buffer = StringBuffer();
    await for (final piece in _generate(input, options)) {
      buffer.write(piece);
    }
    return _result(buffer.toString(), streaming: false);
  }

  @override
  Stream<ChatResult> stream(
    final PromptValue input, {
    final LocalLlmChatModelOptions? options,
  }) {
    return _generate(input, options)
        .map((final piece) => _result(piece, streaming: true));
  }

  Stream<String> _generate(
    final PromptValue input,
    final LocalLlmChatModelOptions? options,
  ) {
    return engine.stream(
      modelName: modelName,
      messages: _toLlmMessages(input.toChatMessages()),
      maxTokens: options?.maxTokens ?? defaultOptions.maxTokens,
      temperature: options?.temperature ?? defaultOptions.temperature,
    );
  }

  ChatResult _result(final String text, {required final bool streaming}) {
    return ChatResult(
      id: 'local-llama-cpp',
      output: AIChatMessage(content: text),
      finishReason: FinishReason.stop,
      metadata: {'model': modelName},
      usage: const LanguageModelUsage(),
      streaming: streaming,
    );
  }

  /// Tool results are folded in as user text: llama.cpp can be given tool
  /// definitions, but nothing in the app wires tools to a local model yet, and
  /// dropping the message outright would lose context the prompt depends on.
  List<LLMMessage> _toLlmMessages(final List<ChatMessage> messages) {
    final out = <LLMMessage>[];
    for (final message in messages) {
      final text = message.contentAsString;
      if (text.isEmpty) continue;
      final role = switch (message) {
        SystemChatMessage() => LLMRole.system,
        AIChatMessage() => LLMRole.assistant,
        _ => LLMRole.user,
      };
      out.add(LLMMessage(role: role, content: text));
    }
    return out;
  }

  /// llama.cpp tokenizes inside its own isolate and the app only uses this for
  /// rough budgeting, so approximate rather than pay for a round trip.
  @override
  Future<List<int>> tokenize(
    final PromptValue promptValue, {
    final LocalLlmChatModelOptions? options,
  }) async {
    final text = promptValue.toString();
    return List<int>.generate(text.length, (final i) => text.codeUnitAt(i));
  }
}
