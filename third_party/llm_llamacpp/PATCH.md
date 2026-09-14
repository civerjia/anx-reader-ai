# Why this package is vendored

`llm_llamacpp` 0.5.0 advertises iOS with Metal, but no iOS build of it can
succeed from a pub.dev install. Three separate things are wrong, all of them on
the iOS path only:

1. **The build hook asks for the wrong kind of artifact.**
   `hook/build.dart` expects the release bundle to contain a `llama.framework`
   *directory*. Dart's `code_assets` validator rejects a directory — a code
   asset has to be a file — so the hook's output never validates. Flutter
   already wraps each dylib code asset in its own framework (`libllama.dylib`
   is installed as `llama.framework/llama`, exactly as the package's own macOS
   loader comment describes), so the artifact it should be asking for is the
   dylib.

2. **The published iOS bundle has no shared library in it.**
   Every other platform's release asset ships one; the iOS asset ships
   `libllama.a` plus the ggml family as static archives. Nothing in the hook
   turns those into a loadable library, so even with (1) fixed the bundle is
   still unusable. The patch links them into `libllama.dylib` with
   `-Wl,-all_load` (required: nothing in the dylib references those objects, so
   the linker would otherwise drop every one of them) and the install name
   Flutter will give it.

3. **The runtime loader assumes static linking.**
   `loadLibrary()` returns `DynamicLibrary.process()` on iOS, which only works
   if the archives were linked into the app executable. With the library
   arriving as a code asset it lives in a framework, so iOS now resolves it the
   same way macOS does, falling back to the process for an embedding that
   really did link statically.

4. **The `LLM_LLAMACPP_LIB_DIR` escape hatch is unreachable under Flutter.**
   Only the pure-Dart loader reads it, but `dart.library.ui` is satisfied under
   `flutter test` as well, so the conditional import always picks the Flutter
   loader — which looks for an app bundle a test host does not have. The
   Flutter loader now checks the variable first, which is what makes an
   end-to-end generation test runnable at all.

5. **Any prompt longer than 512 tokens aborts the process.**
   The inference isolate hands the whole tokenized prompt to a single
   `llama_decode` call, and llama.cpp asserts
   `n_tokens_all <= cparams.n_batch` — an assertion, so it is `ggml_abort`
   taking down the app, not an error the Dart side could catch. `batchSize`
   defaults to 512, and a prompt carrying the app's tool schemas is about 1200
   tokens before any conversation, as is a chapter sent for summary. The prompt
   is now decoded in `n_batch`-sized pieces, which is what llama.cpp's own
   examples do; raising `batchSize` to the context size instead would enlarge
   the compute buffers on every device to cover a case chunking handles for
   free. Fixed at all three call sites — the persistent inference isolate the
   package actually uses, the legacy one-shot isolate, and embeddings.

6. **`think` is accepted and then ignored** — patched for `true` only. `streamChat` and `streamChatWithGenerationOptions` take `think`,
   `StreamChatOptionsMerger` copies it into `MergedOptions`, and nothing in the
   llama.cpp backend ever reads it: no chat-template flag, no `/no_think`, no
   prefilled empty `<think>` block. Whether a Qwen3.5 reply opens with reasoning
   is left entirely to the model. Measured on Qwen3.5-2B with the app's tools
   offered, several replies spent seconds on visible reasoning, and one never
   reached the tool call. Callers that need thinking off have to ask the model
   themselves. `think: true` is now carried to the inference isolate, which
   opens the reply with `<think>` when the model's chat template knows that tag
   (what the template's own `enable_thinking` does); `false` still leaves it to
   the model, since the app's measured tool behaviour was taken that way.

7. **Every request reloaded the model and re-read the whole prompt.**
   The inference isolate loaded the weights, created a context, applied the
   chat template, prefilled every token and then freed all of it — per
   request. With tools and a library digest the system turn alone is about
   2,500 tokens, paid again on every question and every step of an agent loop.
   The model and context are now kept in the isolate between requests, keyed on
   the settings that shape them, and a prompt is put into memory reusing what it
   can: a pure extension evaluates only its new tokens; a model whose memory can
   drop a suffix keeps the shared prefix; otherwise a snapshot of the system
   turn (`llama_state_seq_get_data`) is restored. The snapshot is the case that
   matters for Qwen3.5, whose recurrent layers can be restored whole but not
   rolled back to an arbitrary position. `LlamaCppChatRepository.dispose()` now
   frees the cached model, since killing an isolate never frees native memory.
   The state APIs were already in the bindings, so the ABI fingerprint is
   unchanged.

8. **MiniCPM5 tool calls were not recognised.** MiniCPM5-2B writes
   `<function name="fn"><param name="a">1</param></function>`, none of the
   formats the parser knew, so a call reached the chat as markup and no tool
   ran. It is now a delimited format (`minicpmXml`) with an XML payload parser;
   the stream handler picks it up from the delimiters like the others.

9. **llama.cpp upgraded to b10950, built here, for Spark-X2.5.** 0.5.0's
   prebuilts do not know the `spark2_5` architecture (added upstream on
   2026-09-06, PR #27868). `tool/build_llamacpp_apple.sh` builds the iOS static
   archives into `.native-build/ios-arm64-bundle/`, and the hook now uses a
   bundle there before trying a download. `llama_model_params` gained a field
   (`lazy_mode`) mid-struct, so the headers in `src/include` were replaced and
   the bindings regenerated — which also changes the ABI fingerprint, so the
   release prebuilt could never be picked up by mistake. llama.cpp's
   `llama_chat_apply_template` has no Spark template and would render ChatML;
   `spark_chat_template.dart` renders the model's own format (thinking closed
   unless asked for), and Spark's `<tool_call>fn<arg_key>…</arg_key>
   <arg_value>…</arg_value></tool_call>` calls are a new format, `sparkArgs`.
   A prompt that starts with the BOS text the tokenizer also adds loses the
   duplicate.

Patched files: `hook/build.dart`, `lib/src/spark_chat_template.dart` (new),
`lib/src/tool_calls/tool_definition_formatter.dart`, `lib/src/bindings/llama_bindings.dart` (regenerated), `src/include/*.h`, `lib/src/loader/loader_flutter.dart`,
`lib/src/inference_isolate_handler.dart`, `lib/src/inference_isolate.dart`,
`lib/src/embedding_isolate.dart`, `lib/src/inference_token_generator.dart`,
`lib/src/inference_isolate_messages.dart`, `lib/src/persistent_inference_isolate.dart`,
`lib/src/llamacpp_chat_repository.dart`, `lib/src/llamacpp_chat_repository_impl.dart`,
`lib/src/tool_calls/tool_call_syntax.dart`, `lib/src/tool_call_parser.dart`. None of them is
`lib/src/bindings/llama_bindings.dart`, so the ABI fingerprint — and with it the
prebuilt the build hook downloads — is unchanged.

Unrelated to the build, and worked around in our own code rather than patched
here: `LlamaCppChatRepository.streamChat()` passes a hardcoded
`GenerationOptions()` to its implementation, discarding whatever the caller put
in `LLMChatOptions` — `maxOutputTokens`, `temperature` and `topP` all silently
have no effect. Call `streamChatWithGenerationOptions()` instead.

Drop this directory and the `dependency_overrides` entry once upstream ships an
iOS build that works.
