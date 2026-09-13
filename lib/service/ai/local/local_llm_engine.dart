import 'dart:async';

import 'package:anx_reader/service/ai/local/empty_think_filter.dart';
import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/service/ai/local/local_llm_models.dart';
import 'package:anx_reader/service/ai/local/tool_argument_repair.dart';
import 'package:anx_reader/service/ai/local/context_fit.dart';
import 'dart:convert';
import 'package:anx_reader/utils/log/common.dart';
import 'package:flutter/foundation.dart';
import 'package:llm_llamacpp/llm_llamacpp.dart';

/// Thrown when the configured weights are not on disk.
class LocalLlmModelMissing implements Exception {
  const LocalLlmModelMissing(this.name);
  final String name;

  @override
  String toString() => 'Local model "$name" was not found';
}

/// Something the model produced: visible text, or a request to call tools.
sealed class LocalLlmEvent {
  const LocalLlmEvent();
}

class LocalLlmText extends LocalLlmEvent {
  const LocalLlmText(this.text);
  final String text;
}

/// Reasoning the model wrote before its answer, when thinking is on.
class LocalLlmReasoning extends LocalLlmEvent {
  const LocalLlmReasoning(this.text);
  final String text;
}

/// The model asked for tools. The engine never runs them: the app's agent loop
/// owns execution, so the same tools, confirmation UI and step tiles apply
/// whichever provider is answering.
class LocalLlmToolCalls extends LocalLlmEvent {
  const LocalLlmToolCalls(this.calls);
  final List<LLMToolCall> calls;
}

/// Holds the one loaded llama.cpp model the app keeps in memory.
///
/// A 2B model at Q4 is about 1.4 GB on disk and 1.8 GB resident, so exactly
/// one is loaded at a time and switching models tears the old one down first.
/// Requests are serialized: llama.cpp keeps a single context and interleaving
/// two generations through it would corrupt both.
class LocalLlmEngine {
  LocalLlmEngine._();

  /// Lets a test stand in for the native engine.
  @visibleForTesting
  LocalLlmEngine.fake();

  static final LocalLlmEngine instance = LocalLlmEngine._();

  /// How long to wait for the first piece of a reply.
  ///
  /// Nothing legitimate takes this long: loading a 3 GB model off flash is
  /// about fifteen seconds. A native library that fails to load, on the other
  /// hand, leaves the package's helper isolate waiting for a reply that never
  /// arrives, and without a deadline of our own that surfaces as a spinner
  /// that never stops.
  static const Duration firstChunkDeadline = Duration(seconds: 120);

  LlamaCppChatRepository? _repo;
  String? _loadedPath;
  int? _loadedContext;
  Future<void> _tail = Future<void>.value();

  /// The model currently resident, for the settings page to report.
  String? get loadedModel => _loadedPath;

  /// File name of the model in memory, or null; the unload buttons watch it.
  final ValueNotifier<String?> loaded = ValueNotifier<String?>(null);

  Future<LlamaCppChatRepository> _repositoryFor(String modelName) async {
    final path = await LocalLlmModels.resolve(modelName);
    if (path == null) throw LocalLlmModelMissing(modelName);

    final contextSize = Prefs().localLlmContextSize;
    if (_repo != null && _loadedPath == path && _loadedContext == contextSize) {
      return _repo!;
    }

    if (_repo != null) {
      AnxLog.info('LocalLlm unloading $_loadedPath');
      _repo!.dispose();
      _repo = null;
      _loadedPath = null;
      _loadedContext = null;
    }

    AnxLog.info('LocalLlm loading $path (context $contextSize)');
    // withModelPath loads inside the package's own inference isolate, so the
    // gigabyte-scale read never blocks the UI isolate.
    final repo = LlamaCppChatRepository.withModelPath(
      path,
      contextSize: contextSize,
      nGpuLayers: 99, // Metal on Apple, Vulkan on Android; CPU-only is far slower.
    );
    _repo = repo;
    _loadedPath = path;
    _loadedContext = contextSize;
    loaded.value = path.split('/').last;
    return repo;
  }

  /// Streams a reply as text pieces and, when [tools] are offered and the model
  /// uses them, one [LocalLlmToolCalls] at the end of the turn.
  /// Extra tokens a turn may spend reasoning when thinking is on.
  static const thinkingTokens = 1024;

  Stream<LocalLlmEvent> stream({
    required String modelName,
    required List<LLMMessage> messages,
    List<LLMTool> tools = const [],
    int maxTokens = 640,
    double temperature = 0.7,
    bool think = false,
  }) {
    final out = StreamController<LocalLlmEvent>();
    final lastUser = messages.lastWhere((m) => m.role == LLMRole.user,
        orElse: () => LLMMessage(role: LLMRole.user, content: ''));
    final userText = lastUser.content ?? '';
    // Reasoning comes out of the same budget; without room for it the answer
    // would be cut off or never start.
    final budget = think ? maxTokens + thinkingTokens : maxTokens;

    // The deadline is armed outside the queued work so a helper isolate that
    // never answers still releases whoever is listening.
    final deadline = Timer(firstChunkDeadline, () {
      if (out.isClosed) return;
      out.addError(
        StateError('The local model produced nothing within '
            '${firstChunkDeadline.inSeconds}s. The native library may have '
            'failed to load.'),
      );
      out.close();
    });

    // Queue behind whatever is already generating, and keep the chain intact
    // even when this request fails.
    _tail = _tail.then((_) async {
      final started = DateTime.now();
      var tokens = 0;
      var pieces = 0;
      try {
        final repo = await _repositoryFor(modelName);
        // Room for the tool definitions llama.cpp adds to the prompt, the
        // template's own markup, and the reply itself.
        final toolTokens = tools.fold<int>(
            0, (sum, t) => sum + roughTokens(jsonEncode(t.toJson)));
        final available =
            Prefs().localLlmContextSize - budget - toolTokens - 256;
        final fitted = fitToContext(messages, available);
        if (fitted.clipped > 0 || fitted.dropped > 0) {
          AnxLog.info('LocalLlm prompt fitted to ${Prefs().localLlmContextSize} '
              'context: shortened ${fitted.clipped} earlier turns, left out '
              '${fitted.dropped} (tools ~$toolTokens tokens)');
        }
        // streamChat() discards the caller's options: it hands its
        // implementation a hardcoded GenerationOptions(). This entry point is
        // the one that honours them.
        final stream = repo.streamChatWithGenerationOptions(
          'local',
          messages: fitted.messages,
          // Off by default: at 20 tok/s a few hundred tokens of reasoning is
          // most of a minute. The setting opens the reply with <think>.
          think: think,
          tools: tools,
          // Report calls, never run them: execution belongs to the app.
          options: tools.isEmpty
              ? null
              : LLMChatOptions(tools: tools, autoExecuteTools: false),
          generationOptions: GenerationOptions(
            temperature: temperature,
            topP: 0.9,
            maxTokens: budget,
          ),
        );
        // With thinking asked for, the reply was opened with <think> and runs
        // to </think>. Without, the model still opens with a <think> block of
        // its own (empty, or reasoning), which the chat showed as raw tags.
        final splitter = think ? ThinkSplitter() : null;
        final router = think ? null : LeadingThinkRouter();
        void emitParts(({String reasoning, String answer}) parts) {
          if (out.isClosed) return;
          if (parts.reasoning.isNotEmpty) out.add(LocalLlmReasoning(parts.reasoning));
          if (parts.answer.isNotEmpty) out.add(LocalLlmText(parts.answer));
        }

        void emitText(String text) {
          if (text.isEmpty) return;
          emitParts(splitter?.add(text) ?? router!.add(text));
        }
        await for (final chunk in stream) {
          final message = chunk.message;
          if (chunk.evalCount != null) tokens = chunk.evalCount!;
          if (message == null) continue;

          final piece = message.content;
          if (piece != null && piece.isNotEmpty) {
            deadline.cancel();
            pieces++;
            if (out.isClosed) break;
            emitText(piece);
          }

          final calls = message.toolCalls;
          if (calls != null && calls.isNotEmpty) {
            deadline.cancel();
            if (out.isClosed) break;
            AnxLog.info('LocalLlm requested tools: '
                '${calls.map((c) => '${c.name}(${c.arguments})').join(', ')}');
            final repaired = repairToolCalls(calls, userText);
            for (var i = 0; i < calls.length; i++) {
              if (repaired[i].arguments != calls[i].arguments) {
                AnxLog.info('LocalLlm tool arguments put back to the user\'s '
                    'words: ${calls[i].arguments} -> ${repaired[i].arguments}');
              }
            }
            out.add(LocalLlmToolCalls(repaired));
          }
        }
        emitParts(splitter?.close() ?? router!.close());
        final seconds = DateTime.now().difference(started).inMilliseconds / 1000;
        final generated = tokens > 0 ? tokens : pieces;
        final capped = tokens >= budget ? ' — hit the $budget token cap' : '';
        AnxLog.info('LocalLlm $generated tokens in '
            '${seconds.toStringAsFixed(1)}s'
            '${seconds > 0 ? ' (${(generated / seconds).toStringAsFixed(1)} tok/s)' : ''}'
            ' with ${tools.length} tools offered${think ? ', thinking' : ''}$capped');
      } catch (e, st) {
        AnxLog.severe('LocalLlm generation failed: $e\n$st');
        if (!out.isClosed) out.addError(e, st);
      } finally {
        deadline.cancel();
        if (!out.isClosed) await out.close();
      }
    });

    return out.stream;
  }

  /// Drops the resident model. Worth calling when the user switches away from
  /// the local provider, since nothing else will reclaim the 1.8 GB.
  void unload() {
    if (_repo != null) AnxLog.info('LocalLlm unloading $_loadedPath on request');
    _repo?.dispose();
    _repo = null;
    _loadedPath = null;
    _loadedContext = null;
    loaded.value = null;
  }

  /// Unloads once any answer being generated has finished, so the button never
  /// pulls the model out from under a reply. Held in memory, 1.8 GB made the
  /// whole phone sluggish between the occasional questions.
  Future<void> unloadWhenIdle() {
    final done = _tail.then((_) => unload());
    _tail = done.catchError((Object _) {});
    return done;
  }
}
