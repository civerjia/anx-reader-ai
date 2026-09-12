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

Patched files: `hook/build.dart`, `lib/src/loader/loader_flutter.dart`,
`lib/src/inference_isolate_handler.dart`, `lib/src/inference_isolate.dart`,
`lib/src/embedding_isolate.dart`. None of them is
`lib/src/bindings/llama_bindings.dart`, so the ABI fingerprint — and with it the
prebuilt the build hook downloads — is unchanged.

Unrelated to the build, and worked around in our own code rather than patched
here: `LlamaCppChatRepository.streamChat()` passes a hardcoded
`GenerationOptions()` to its implementation, discarding whatever the caller put
in `LLMChatOptions` — `maxOutputTokens`, `temperature` and `topP` all silently
have no effect. Call `streamChatWithGenerationOptions()` instead.

Drop this directory and the `dependency_overrides` entry once upstream ships an
iOS build that works.
