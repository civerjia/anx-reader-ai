# Vendored dependency patches

These path packages are wired through `dependency_overrides` in the root `pubspec.yaml`.

## llm_llamacpp
- Make the iOS build work at all: the hook asked for a `.framework` directory where a dylib is required, the published iOS bundle ships only static archives, and the runtime loader assumed static linking. See `llm_llamacpp/PATCH.md`.

## googleai_dart
- Preserve `thoughtSignature` on `FunctionCallPart` during JSON parse/serialize (Gemini thinking models).

## langchain_google
- Cache raw Gemini `Content` (including thought signatures) when tool calls are returned, and replay that content on the next history turn so tool round-trips do not drop signatures (#977).

Remove these overrides once upstream `langchain_google` / `googleai_dart` versions that include the fix are compatible with our langchain forks.
