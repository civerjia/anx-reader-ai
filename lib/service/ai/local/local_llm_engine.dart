import 'dart:async';

import 'package:anx_reader/service/ai/local/local_llm_models.dart';
import 'package:flutter/foundation.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:llm_llamacpp/llm_llamacpp.dart';

/// Thrown when the configured weights are not on disk.
class LocalLlmModelMissing implements Exception {
  const LocalLlmModelMissing(this.name);
  final String name;

  @override
  String toString() => 'Local model "$name" was not found';
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

  /// Enough for a chapter excerpt plus an answer, without paying for KV cache
  /// the reader will never use. Qwen3.5 trains at 256k; a phone cannot afford
  /// anything close to that.
  static const int contextSize = 4096;

  LlamaCppChatRepository? _repo;
  String? _loadedPath;
  Future<void> _tail = Future<void>.value();

  /// The model currently resident, for the settings page to report.
  String? get loadedModel => _loadedPath;

  Future<LlamaCppChatRepository> _repositoryFor(String modelName) async {
    final path = await LocalLlmModels.resolve(modelName);
    if (path == null) throw LocalLlmModelMissing(modelName);

    if (_repo != null && _loadedPath == path) return _repo!;

    if (_repo != null) {
      AnxLog.info('LocalLlm unloading $_loadedPath');
      _repo!.dispose();
      _repo = null;
      _loadedPath = null;
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
    return repo;
  }

  /// Streams a reply, one piece of text at a time.
  Stream<String> stream({
    required String modelName,
    required List<LLMMessage> messages,
    int maxTokens = 640,
    double temperature = 0.7,
  }) {
    final out = StreamController<String>();

    // Queue behind whatever is already generating, and keep the chain intact
    // even when this request fails.
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

    _tail = _tail.then((_) async {
      final started = DateTime.now();
      var tokens = 0;
      try {
        final repo = await _repositoryFor(modelName);
        // streamChat() discards the caller's options: it hands its
        // implementation a hardcoded GenerationOptions(). This entry point is
        // the one that honours them.
        final stream = repo.streamChatWithGenerationOptions(
          'local',
          messages: messages,
          think: false, // Qwen3.5 would otherwise spend a few hundred tokens reasoning.
          generationOptions: GenerationOptions(
            temperature: temperature,
            topP: 0.9,
            maxTokens: maxTokens,
          ),
        );
        await for (final chunk in stream) {
          final piece = chunk.message?.content;
          if (piece != null && piece.isNotEmpty) {
            deadline.cancel();
            tokens = chunk.evalCount ?? tokens;
            if (out.isClosed) break;
            out.add(piece);
          }
        }
        final seconds = DateTime.now().difference(started).inMilliseconds / 1000;
        if (tokens > 0 && seconds > 0) {
          AnxLog.info('LocalLlm $tokens tokens in '
              '${seconds.toStringAsFixed(1)}s '
              '(${(tokens / seconds).toStringAsFixed(1)} tok/s)');
        }
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
    _repo?.dispose();
    _repo = null;
    _loadedPath = null;
  }
}
