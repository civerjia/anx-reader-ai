import 'dart:convert';

import 'package:anx_reader/service/ai/local/local_llm_engine.dart';
import 'package:flutter/foundation.dart';
import 'package:langchain_core/chat_models.dart';
import 'package:langchain_core/language_models.dart';
import 'package:langchain_core/prompts.dart';
import 'package:langchain_core/tools.dart';
import 'package:llm_llamacpp/llm_llamacpp.dart'
    show LLMMessage, LLMRole, LLMTool, LLMToolCall, LLMToolParam;

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
/// the chat page and its tools — work against a local model without touching
/// any of them.
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

  /// Every call in one process gets a distinct id. llama.cpp parses calls out of
  /// raw text and has no id to give, and langchain merges streamed calls *by*
  /// id, so two calls sharing one would be concatenated into a single garbled
  /// call.
  static int _callCounter = 0;

  @override
  String get modelType => 'local-llama-cpp';

  @override
  Future<ChatResult> invoke(
    final PromptValue input, {
    final LocalLlmChatModelOptions? options,
  }) async {
    ChatResult? aggregated;
    await for (final chunk in stream(input, options: options)) {
      aggregated = aggregated == null ? chunk : aggregated.concat(chunk);
    }
    final result = aggregated ?? _result(const AIChatMessage(content: ''));
    return ChatResult(
      id: result.id,
      output: result.output,
      finishReason: result.finishReason,
      metadata: result.metadata,
      usage: result.usage,
      streaming: false,
    );
  }

  @override
  Stream<ChatResult> stream(
    final PromptValue input, {
    final LocalLlmChatModelOptions? options,
  }) {
    final specs = options?.tools ?? defaultOptions.tools ?? const <ToolSpec>[];
    return engine
        .stream(
          modelName: modelName,
          messages: toLlmMessages(input.toChatMessages()),
          tools: [for (final spec in specs) SchemaTool(spec)],
          maxTokens: options?.maxTokens ?? defaultOptions.maxTokens,
          temperature: options?.temperature ?? defaultOptions.temperature,
        )
        .map(
          (final event) => switch (event) {
            LocalLlmText(:final text) =>
              _result(AIChatMessage(content: text)),
            LocalLlmToolCalls(:final calls) => _result(
                AIChatMessage(
                  content: '',
                  toolCalls: [for (final call in calls) _toLangchain(call)],
                ),
                finishReason: FinishReason.toolCalls,
              ),
          },
        );
  }

  ChatResult _result(
    final AIChatMessage message, {
    final FinishReason finishReason = FinishReason.stop,
  }) {
    return ChatResult(
      id: 'local-llama-cpp',
      output: message,
      finishReason: finishReason,
      metadata: {'model': modelName},
      usage: const LanguageModelUsage(),
      streaming: true,
    );
  }

  AIChatMessageToolCall _toLangchain(final LLMToolCall call) {
    Map<String, dynamic> arguments;
    try {
      arguments = call.argumentsJson;
    } catch (_) {
      // Kept raw: the agent loop reports the bad input back to the model as a
      // tool error, which gives it a chance to correct itself.
      arguments = const {};
    }
    return AIChatMessageToolCall(
      id: 'local-call-${++_callCounter}',
      name: call.name,
      argumentsRaw: call.arguments,
      arguments: arguments,
    );
  }

  /// Converts the langchain conversation into what llama.cpp's template takes.
  ///
  /// llama.cpp only receives role and content strings, so a turn in which the
  /// model called tools has to be written back out with its `<tool_call>` markup.
  /// Replaying only the visible text would show the model a turn that announced
  /// a tool and then answered without calling one, and it would copy that.
  @visibleForTesting
  static List<LLMMessage> toLlmMessages(final List<ChatMessage> messages) {
    final out = <LLMMessage>[];
    for (final message in messages) {
      switch (message) {
        case AIChatMessage(:final toolCalls) when toolCalls.isNotEmpty:
          final calls = toolCalls
              .map((call) => '<tool_call>\n'
                  '${jsonEncode({
                    'name': call.name,
                    'arguments': call.arguments.isNotEmpty
                        ? call.arguments
                        : _decodeOrEmpty(call.argumentsRaw),
                  })}\n'
                  '</tool_call>')
              .join('\n');
          final visible = message.content.trim();
          out.add(LLMMessage(
            role: LLMRole.assistant,
            content: visible.isEmpty ? calls : '$visible\n$calls',
          ));
        case ToolChatMessage(:final toolCallId, :final content):
          out.add(LLMMessage(
            role: LLMRole.tool,
            toolCallId: toolCallId,
            // An empty result still has to be a turn, or the call is left
            // unanswered and the model asks again.
            content: content.isEmpty ? '(no result)' : clipToolResult(content),
          ));
        default:
          final text = message.contentAsString;
          if (text.isEmpty) continue;
          out.add(LLMMessage(
            role: switch (message) {
              SystemChatMessage() => LLMRole.system,
              AIChatMessage() => LLMRole.assistant,
              _ => LLMRole.user,
            },
            content: text,
          ));
      }
    }

    // Exactly one system turn, and first. The agent loop puts its own system
    // prompt in front of a history that can already hold one — the library
    // digest arrives that way — and a chat template like Qwen's accepts a
    // system message only at the start. llama.cpp also appends the tool
    // definitions to the first system turn it finds, so a second one would sit
    // after them, cut off from the instructions it qualifies.
    final systems = [
      for (final m in out)
        if (m.role == LLMRole.system && (m.content?.isNotEmpty ?? false))
          m.content!,
    ];
    final rest = [for (final m in out) if (m.role != LLMRole.system) m];
    return [
      if (systems.isNotEmpty)
        LLMMessage(role: LLMRole.system, content: systems.join('\n\n')),
      ...rest,
    ];
  }

  /// The most of one tool result a local model is shown.
  ///
  /// The chapter tool returns the whole chapter when the model does not ask for
  /// less, and a Chinese chapter runs to tens of thousands of characters — at
  /// roughly one token each, several times the context a phone loads. A remote
  /// model has room for that; this one would overflow before it could answer.
  static const int toolResultCharacterLimit = 6000;

  @visibleForTesting
  static String clipToolResult(final String content) {
    if (content.length <= toolResultCharacterLimit) return content;
    final kept = content.substring(0, toolResultCharacterLimit);
    // Said to the model, so it knows the result was cut rather than complete
    // and does not present a partial list as the whole of it.
    return '$kept\n…[truncated: showing $toolResultCharacterLimit of '
        '${content.length} characters]';
  }

  static Map<String, dynamic> _decodeOrEmpty(final String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : const {};
    } catch (_) {
      return const {};
    }
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

/// Offers an app tool to llama.cpp by its JSON schema, without the ability to
/// run it.
///
/// The package describes tools through [LLMTool], whose parameter list cannot
/// express everything the app's schemas use (nested objects of arrays, for the
/// bookshelf plan). The schema is what reaches the model anyway, so it is passed
/// through untouched instead of being squeezed into [LLMToolParam]s.
@visibleForTesting
class SchemaTool extends LLMTool {
  SchemaTool(this.spec);

  final ToolSpec spec;

  @override
  String get name => spec.name;

  @override
  String get description => spec.description;

  @override
  List<LLMToolParam> get parameters => const [];

  @override
  Map<String, dynamic> get toJson => {
        'type': 'function',
        'function': {
          'name': spec.name,
          'description': spec.description,
          'parameters': spec.inputJsonSchema,
        },
      };

  @override
  Future<dynamic> execute(Map<String, dynamic> args, {dynamic extra}) {
    throw StateError('${spec.name} is executed by the app, not by llama.cpp');
  }
}
