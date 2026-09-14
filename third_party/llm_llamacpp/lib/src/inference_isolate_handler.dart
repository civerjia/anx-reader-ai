part of 'persistent_inference_isolate.dart';

void _handleInferenceRequest(
  _InferenceRequestMessage request,
  SendPort mainSendPort,
  ffi.DynamicLibrary lib,
  LlamaBindings bindings,
) {
  try {
    // The model and its context outlive the request: reloading 1.4 GB of
    // weights, rebuilding Metal pipelines and prefilling the same system turn
    // on every question was most of what a phone spent before the first token.
    final session = _acquireSession(request, bindings, mainSendPort);
    if (session == null) return;
    final model = session.model;
    final ctx = session.ctx;
    final vocab = bindings.llama_model_get_vocab(model);

    try {
      String prompt;
      // Inspect the model's GGUF chat template so we can correctly compensate
      // for cases where llama_chat_apply_template's hard-coded fallback drops
      // the leading BOS that the real Jinja template would emit.
      String? modelTemplateStr;
      final templatePtr = bindings.llama_model_chat_template(
        model,
        ffi.nullptr,
      );
      if (templatePtr.address != 0) {
        try {
          modelTemplateStr = templatePtr.cast<Utf8>().toDartString();
        } catch (_) {
          modelTemplateStr = null;
        }
      }

      if (request.messages != null && request.messages!.isNotEmpty) {
        prompt = _applyNativeChatTemplate(
          bindings,
          model,
          request.messages!,
          toolSchemasJson: request.toolSchemasJson,
        );
      } else {
        prompt = request.prompt;
      }

      // llama_chat_apply_template is NOT a Jinja interpreter; if the model's
      // GGUF template starts with `{{- bos_token -}}` (LFM2.5, some Llama 3
      // variants, etc.), the fallback chatml formatter drops the BOS. The
      // tokenizer's `add_bos_token` flag is also frequently false on such
      // models, because the template is supposed to handle BOS itself. Net
      // result: no BOS token in the prompt → model behaves like a base model
      // and never produces an EOS. Detect this and prepend the BOS id by hand.
      final usingChatTemplate =
          request.messages != null && request.messages!.isNotEmpty;
      // `think` was accepted and ignored. For a template that knows <think>
      // (Qwen3), opening the reply with it is what its own enable_thinking
      // does; llama_chat_apply_template has no such flag.
      if (usingChatTemplate && isSparkChatTemplate(modelTemplateStr)) {
        // Spark thinks unless the reply is opened closed, as its template's
        // enable_thinking=false does; a phone cannot wait for that by default.
        prompt = request.think ? '$prompt<think>' : '$prompt</think>';
      } else if (request.think &&
          usingChatTemplate &&
          (modelTemplateStr?.contains('<think>') ?? false)) {
        prompt = '$prompt<think>\n';
      }
      final addBosByTokenizer = bindings.llama_vocab_get_add_bos(vocab);
      // A template that writes its own BOS text, tokenized with add_special,
      // would start with two of them.
      if (usingChatTemplate && addBosByTokenizer) {
        final bosId = bindings.llama_vocab_bos(vocab);
        if (bosId >= 0) {
          final bosText =
              bindings.llama_vocab_get_text(vocab, bosId).cast<Utf8>().toDartString();
          if (bosText.isNotEmpty && prompt.startsWith(bosText)) {
            prompt = prompt.substring(bosText.length);
          }
        }
      }
      final templateRefersToBos =
          modelTemplateStr != null &&
          (modelTemplateStr.contains('bos_token') ||
              modelTemplateStr.contains('<|begin_of_text|>') ||
              modelTemplateStr.contains('<|startoftext|>'));
      final shouldManuallyPrependBos =
          usingChatTemplate && templateRefersToBos && !addBosByTokenizer;
      // ignore: avoid_print
      print(
        '[inference_isolate_handler] BOS handling: '
        'add_bos_token=$addBosByTokenizer '
        'template_refers_to_bos=$templateRefersToBos '
        'manual_bos_prepend=$shouldManuallyPrependBos',
      );

      final promptPtr = prompt.toNativeUtf8();
      // Use UTF-8 byte length, not Dart string length (UTF-16 code units), so
      // that prompts with non-ASCII characters tokenize correctly.
      final promptByteLen = promptPtr.length;
      final maxTokens = promptByteLen + 256;
      final tokensPtr = calloc<ffi.Int32>(maxTokens);

      // When we'll manually prepend BOS, ask the tokenizer NOT to add specials.
      // Otherwise keep the prior behavior so the tokenizer's configured
      // BOS/EOS handling stays in effect.
      final tokenizerAddSpecial = !shouldManuallyPrependBos;
      final nTokensFromTokenizer = bindings.llama_tokenize(
        vocab,
        promptPtr.cast(),
        promptByteLen,
        tokensPtr,
        maxTokens,
        tokenizerAddSpecial,
        true,
      );
      calloc.free(promptPtr);

      if (nTokensFromTokenizer < 0) {
        calloc.free(tokensPtr);
        // ignore: avoid_print
        print(
          '[inference_isolate_handler] Tokenization failed '
          '(returned $nTokensFromTokenizer) '
          'for prompt of ${prompt.length} chars / $promptByteLen bytes',
        );
        mainSendPort.send(
          _IsolateResponse(
            requestId: request.requestId,
            payload: InferenceError('Failed to tokenize prompt'),
            isComplete: true,
          ),
        );
        return;
      }

      var nTokens = nTokensFromTokenizer;
      if (shouldManuallyPrependBos) {
        final bosId = bindings.llama_vocab_bos(vocab);
        if (bosId >= 0) {
          // Shift right by 1 to make room for BOS at index 0.
          for (var i = nTokens; i > 0; i--) {
            tokensPtr[i] = tokensPtr[i - 1];
          }
          tokensPtr[0] = bosId;
          nTokens += 1;
          // ignore: avoid_print
          print(
            '[inference_isolate_handler] Manually prepended BOS token id=$bosId; '
            'prompt now $nTokens tokens',
          );
        } else {
          // ignore: avoid_print
          print(
            '[inference_isolate_handler] WARNING: wanted to prepend BOS but '
            'llama_vocab_bos returned $bosId',
          );
        }
      }

      // ignore: avoid_print
      print(
        '[inference_isolate_handler] Tokenized prompt: $nTokens tokens '
        '(${prompt.length} chars, contextSize=${request.contextSize})',
      );

      // Decode the first few tokens so we can see whether ChatML markers like
      // `<|im_start|>` are tokenizing as single special tokens or being split
      // into many literal-character tokens. The latter is a strong sign that
      // the model's vocab does not contain those markers and the chat
      // template we used is wrong for this model.
      try {
        final previewCount = nTokens < 15 ? nTokens : 15;
        final pieceBuf = calloc<ffi.Char>(64);
        final preview = StringBuffer();
        try {
          for (var i = 0; i < previewCount; i++) {
            final id = tokensPtr[i];
            final pieceLen = bindings.llama_token_to_piece(
              vocab,
              id,
              pieceBuf,
              64,
              0,
              true,
            );
            String text;
            if (pieceLen <= 0) {
              text = '?';
            } else {
              text = pieceBuf
                  .cast<Utf8>()
                  .toDartString(length: pieceLen)
                  .replaceAll('\n', r'\n')
                  .replaceAll('\r', r'\r');
            }
            preview.write('  [$i] id=$id "$text"\n');
          }
        } finally {
          calloc.free(pieceBuf);
        }
        // ignore: avoid_print
        print(
          '[inference_isolate_handler] First $previewCount token(s):\n$preview',
        );
      } catch (e) {
        // ignore: avoid_print
        print('[inference_isolate_handler] Could not preview tokens: $e');
      }

      final promptTokens = List<int>.of(tokensPtr.asTypedList(nTokens));
      final evaluated = _evaluatePrompt(
        bindings,
        session,
        tokensPtr,
        promptTokens,
        _systemTurnTokens(
          bindings,
          model,
          vocab,
          request,
          addSpecial: tokenizerAddSpecial,
          prependBos: shouldManuallyPrependBos,
        ),
        request.batchSize,
      );
      if (!evaluated) {
        calloc.free(tokensPtr);
        mainSendPort.send(
          _IsolateResponse(
            requestId: request.requestId,
            payload: InferenceError('Failed to evaluate prompt'),
            isComplete: true,
          ),
        );
        return;
      }

      final sampler = _configureSampler(
        bindings,
        request.options,
        bindings.llama_vocab_n_tokens(bindings.llama_model_get_vocab(model)),
      );

      // Caller-supplied stops plus the markers detected from the rendered
      // template. See `resolveStopTokens` for why detection is additive.
      final effectiveStopTokens = resolveStopTokens(
        requested: request.stopTokens,
        prompt: prompt,
        onDiagnostic: (message) {
          // ignore: avoid_print
          print('[inference_isolate_handler] $message');
        },
      );

      final generatedTokens = _generateTokens(
        bindings,
        model,
        ctx,
        sampler,
        vocab,
        request.options,
        effectiveStopTokens,
        request.requestId,
        mainSendPort,
        session.tokens,
      );

      bindings.llama_sampler_free(sampler);
      calloc.free(tokensPtr);

      mainSendPort.send(
        _IsolateResponse(
          requestId: request.requestId,
          payload: InferenceComplete(
            promptTokens: nTokens,
            generatedTokens: generatedTokens,
          ),
          isComplete: true,
        ),
      );
    } catch (_) {
      // What the context's memory holds after a failure is unknown, so the
      // next request must not trust it.
      session.tokens = [];
      rethrow;
    }
  } catch (e) {
    mainSendPort.send(
      _IsolateResponse(
        requestId: request.requestId,
        payload: InferenceError(e.toString()),
        isComplete: true,
      ),
    );
  }
}

/// Shortest prefix worth a state snapshot. Restoring costs a copy of the KV
/// cache and recurrent state; below this, prefilling again is as quick.
const int _minReusableTokens = 128;

/// A loaded model and context kept between requests, and what it holds.
class _CachedSession {
  _CachedSession(this.key, this.model, this.ctx, this.lora);

  final String key;
  final ffi.Pointer<llama_model> model;
  final ffi.Pointer<llama_context> ctx;
  final ffi.Pointer<llama_adapter_lora>? lora;

  /// Tokens currently in sequence 0 of the context's memory, in order.
  List<int> tokens = [];

  /// A snapshot of sequence 0 taken after [checkpointTokens] were evaluated.
  List<int>? checkpointTokens;
  Uint8List? checkpointState;
}

_CachedSession? _session;

String _sessionKey(_InferenceRequestMessage r) => [
      r.modelPath,
      r.nGpuLayers,
      r.contextSize,
      r.batchSize,
      r.threads,
      r.loraPath,
      r.loraScale,
    ].join('|');

_CachedSession? _acquireSession(
  _InferenceRequestMessage request,
  LlamaBindings bindings,
  SendPort mainSendPort,
) {
  final key = _sessionKey(request);
  final existing = _session;
  if (existing != null && existing.key == key) return existing;
  _releaseSession(bindings);

  void fail(String message) => mainSendPort.send(
        _IsolateResponse(
          requestId: request.requestId,
          payload: InferenceError(message),
          isComplete: true,
        ),
      );

  final modelParams = bindings.llama_model_default_params();
  modelParams.n_gpu_layers = request.nGpuLayers;
  final modelPathPtr = request.modelPath.toNativeUtf8();
  final model = bindings.llama_model_load_from_file(
    modelPathPtr.cast(),
    modelParams,
  );
  calloc.free(modelPathPtr);
  if (model.address == 0) {
    fail('Failed to load model from ${request.modelPath}');
    return null;
  }

  ffi.Pointer<llama_adapter_lora>? lora;
  if (request.loraPath != null) {
    final loraPathPtr = request.loraPath!.toNativeUtf8();
    lora = bindings.llama_adapter_lora_init(model, loraPathPtr.cast());
    calloc.free(loraPathPtr);
    if (lora.address == 0) {
      bindings.llama_model_free(model);
      fail('Failed to load LoRA adapter');
      return null;
    }
  }

  final ctxParams = bindings.llama_context_default_params();
  ctxParams.n_ctx = request.contextSize;
  ctxParams.n_batch = request.batchSize;
  if (request.threads != null) {
    ctxParams.n_threads = request.threads!;
    ctxParams.n_threads_batch = request.threads!;
  }
  final ctx = bindings.llama_init_from_model(model, ctxParams);
  if (ctx.address == 0) {
    if (lora != null) bindings.llama_adapter_lora_free(lora);
    bindings.llama_model_free(model);
    fail('Failed to create context');
    return null;
  }

  if (lora != null &&
      setSingleContextLoraAdapter(bindings, ctx, lora, request.loraScale) != 0) {
    bindings.llama_free(ctx);
    bindings.llama_adapter_lora_free(lora);
    bindings.llama_model_free(model);
    fail('Failed to apply LoRA adapter');
    return null;
  }

  // ignore: avoid_print
  print('[prefix-cache] loaded ${request.modelPath} '
      '(context ${request.contextSize}, batch ${request.batchSize})');
  return _session = _CachedSession(key, model, ctx, lora);
}

/// Frees the cached model. Nothing else reclaims its memory: the isolate lives
/// as long as the app, and killing an isolate never frees native allocations.
void _releaseSession(LlamaBindings bindings) {
  final s = _session;
  if (s == null) return;
  _session = null;
  if (s.lora != null) {
    clearContextLoraAdapters(bindings, s.ctx);
    bindings.llama_adapter_lora_free(s.lora!);
  }
  bindings.llama_free(s.ctx);
  bindings.llama_model_free(s.model);
  // ignore: avoid_print
  print('[prefix-cache] released ${s.key.split('|').first}');
}

int _commonPrefix(List<int> a, List<int> b) {
  final n = a.length < b.length ? a.length : b.length;
  var i = 0;
  while (i < n && a[i] == b[i]) {
    i++;
  }
  return i;
}

/// Evaluates tokens [from, to) in n_batch-sized pieces. llama_decode aborts
/// the process — it does not fail — when one batch is larger than n_batch.
bool _decodeRange(
  LlamaBindings bindings,
  ffi.Pointer<llama_context> ctx,
  ffi.Pointer<ffi.Int32> tokens,
  int from,
  int to,
  int batchSize,
) {
  final nBatch = batchSize > 0 ? batchSize : to - from;
  for (var offset = from; offset < to; offset += nBatch) {
    final count = to - offset < nBatch ? to - offset : nBatch;
    final batch = bindings.llama_batch_get_one(tokens + offset, count);
    if (bindings.llama_decode(ctx, batch) != 0) return false;
  }
  return true;
}

/// The tokens of the rendered system turn — system prompt plus any injected
/// tool definitions — or null when the conversation has none.
///
/// This is what stays the same from one question to the next, so it is where
/// a snapshot is taken. Rendering it alone and comparing tokens, rather than
/// searching the text for a template marker, keeps this independent of the
/// model family's chat format.
List<int>? _systemTurnTokens(
  LlamaBindings bindings,
  ffi.Pointer<llama_model> model,
  ffi.Pointer<llama_vocab> vocab,
  _InferenceRequestMessage request, {
  required bool addSpecial,
  required bool prependBos,
}) {
  final messages = request.messages;
  if (messages == null || messages.isEmpty || messages.first.role != 'system') {
    return null;
  }
  final rendered = _applyNativeChatTemplate(
    bindings,
    model,
    [messages.first],
    toolSchemasJson: request.toolSchemasJson,
  );
  final ptr = rendered.toNativeUtf8();
  final byteLen = ptr.length;
  final capacity = byteLen + 256;
  final buf = calloc<ffi.Int32>(capacity);
  try {
    final n = bindings.llama_tokenize(
        vocab, ptr.cast(), byteLen, buf, capacity, addSpecial, true);
    if (n <= 0) return null;
    final tokens = List<int>.of(buf.asTypedList(n));
    if (prependBos) {
      final bos = bindings.llama_vocab_bos(vocab);
      if (bos >= 0) tokens.insert(0, bos);
    }
    return tokens;
  } finally {
    calloc.free(ptr);
    calloc.free(buf);
  }
}

/// Puts [prompt] into the context's memory, reusing as much as possible.
///
/// In order: a prompt that only extends what memory holds evaluates just the
/// new tokens; a model whose memory can drop a suffix keeps the shared prefix;
/// otherwise the snapshot of the system turn is restored. Qwen3.5 lands on the
/// last case — its recurrent layers cannot be rolled back to an arbitrary
/// position, only restored whole — which is why a snapshot, not a truncation,
/// is what makes a second question cheap.
bool _evaluatePrompt(
  LlamaBindings bindings,
  _CachedSession s,
  ffi.Pointer<ffi.Int32> tokensPtr,
  List<int> prompt,
  List<int>? systemTurn,
  int batchSize,
) {
  final mem = bindings.llama_get_memory(s.ctx);
  void log(String how, int reused) {
    // ignore: avoid_print
    print('[prefix-cache] $how: reused $reused of ${prompt.length} tokens, '
        'evaluated ${prompt.length - reused}');
  }

  bool finish(int from, String how) {
    log(how, from);
    final ok = _decodeRange(
        bindings, s.ctx, tokensPtr, from, prompt.length, batchSize);
    s.tokens = ok ? List<int>.of(prompt) : [];
    return ok;
  }

  final held = s.tokens;
  if (held.isNotEmpty && prompt.length > held.length) {
    if (_commonPrefix(prompt, held) == held.length) {
      return finish(held.length, 'extension');
    }
  }

  final shared = _commonPrefix(prompt, held);
  if (shared >= _minReusableTokens &&
      shared < prompt.length &&
      bindings.llama_memory_seq_rm(mem, 0, shared, -1)) {
    return finish(shared, 'trimmed');
  }

  var start = 0;
  final cp = s.checkpointTokens;
  final cpState = s.checkpointState;
  final cpMatches = cp != null &&
      cpState != null &&
      prompt.length > cp.length &&
      _commonPrefix(prompt, cp) == cp.length;
  bindings.llama_memory_clear(mem, true);
  if (cpMatches) {
    final src = calloc<ffi.Uint8>(cpState.length);
    src.asTypedList(cpState.length).setAll(0, cpState);
    final read = bindings.llama_state_seq_set_data(
        s.ctx, src, cpState.length, 0);
    calloc.free(src);
    if (read > 0) {
      start = cp.length;
    } else {
      bindings.llama_memory_clear(mem, true);
    }
  }

  final boundary = systemTurn == null
      ? 0
      : [_commonPrefix(prompt, systemTurn), prompt.length - 1]
          .reduce((a, b) => a < b ? a : b);
  if (start == 0 && boundary >= _minReusableTokens) {
    if (!_decodeRange(bindings, s.ctx, tokensPtr, 0, boundary, batchSize)) {
      s.tokens = [];
      return false;
    }
    final size = bindings.llama_state_seq_get_size(s.ctx, 0);
    final dst = calloc<ffi.Uint8>(size);
    final written = bindings.llama_state_seq_get_data(s.ctx, dst, size, 0);
    if (written > 0) {
      s.checkpointState = Uint8List.fromList(dst.asTypedList(written));
      s.checkpointTokens = prompt.sublist(0, boundary);
      // ignore: avoid_print
      print('[prefix-cache] snapshot of the system turn: $boundary tokens, '
          '${(written / 1048576).toStringAsFixed(1)} MiB');
    }
    calloc.free(dst);
    start = boundary;
    return finish(start, 'snapshot taken');
  }
  return finish(start, cpMatches && start > 0 ? 'snapshot restored' : 'full');
}
