# A local model for the AI features

Anx can run the AI features against a model on the device, through
[llama.cpp](https://github.com/ggml-org/llama.cpp). No API key, no network, no
per token billing — which is the point: it is the only way the excerpt menu and
the chat page still work with no signal.

It plugs in as another AI provider, so everything that already asks a model a
question uses it unchanged: the excerpt menu (explain, translate, look up),
chapter and book summaries, and the chat page behind the ✨ tab.

## 1. Get a model

Weights are GGUF files. Convert-it-yourself is unnecessary — take a quantized
build from Hugging Face.

```bash
# Qwen3.5-2B, Q4_K_M (~1.4 GB). The recommended starting point.
curl -L -o Qwen_Qwen3.5-2B-Q4_K_M.gguf \
  https://huggingface.co/bartowski/Qwen_Qwen3.5-2B-GGUF/resolve/main/Qwen_Qwen3.5-2B-Q4_K_M.gguf
```

Use conversions from the model authors, [unsloth](https://huggingface.co/unsloth)
or [bartowski](https://huggingface.co/bartowski). Some converters omit metadata
llama.cpp needs for a given architecture, and the failure looks like
`key not found in model: <arch>.rope.dimension_sections`.

### Which size

Measured on an iPhone 16 Pro (A18 Pro), Q4_K_M, Metal, 4096 context:

| | Qwen3.5-2B | Qwen3.5-4B |
| --- | --- | --- |
| File | 1.40 GB | 3.01 GB |
| Prefill | 183–200 tok/s | 37–55 tok/s |
| Decode | 18–26 tok/s | 7.2–8.7 tok/s |
| Peak memory | 1.75 GB | 3.06 GB |
| Starts from cold | yes | **killed by the OS** |

**2B is the size that works on a phone.** 4B exceeds the per-app memory limit and
gets terminated; even with the `increased-memory-limit` entitlement it decodes at
around 8 tok/s, which is about forty seconds for a short answer.

For reference, the same 4B file on an M4 Pro does 232 tok/s prefill and 43–49
tok/s decode — a desktop is a different question entirely, and there 4B is
comfortable.

Explaining a 185 token passage with the 2B model takes 0.9 s of prefill and 6.8 s
to write 176 tokens: **about eight seconds end to end**. The first request after
launch additionally pays roughly 14 s to read the weights off flash.

## 2. Put it where Anx looks

Anx scans, in order:

- `<documents>/llm_models/`
- `<documents>/`
- `<anx document path>/llm_models/`
- `<anx document path>/`

On iOS and macOS the documents directory is the one exposed to Finder and the
Files app, so `llm_models` is the folder to drop the file into. On a device with
a cable:

```bash
xcrun devicectl device copy to --device <udid> \
  --domain-type appDataContainer --domain-identifier com.shuangzhou.anxreader \
  --source Qwen_Qwen3.5-2B-Q4_K_M.gguf \
  --destination Documents/llm_models/Qwen_Qwen3.5-2B-Q4_K_M.gguf
```

Never add `--remove-existing-content` to that command: it empties the
destination's parent directory first.

Only the file name is stored in settings, never the full path — an iOS app's data
container UUID changes between installs, so a stored path stops resolving after a
reinstall.

## 3. Point Anx at it

Settings → AI → provider centre → **+**, then:

- **Protocol**: Local (on-device)
- **Model file**: pick the `.gguf` from the dropdown (press *Rescan* if you added
  it while the page was open)

There is no URL and no API key to fill in; those fields are hidden for this
protocol. Set it as the default provider and every AI feature uses it.

Keep a cloud provider configured alongside it. Switching default providers is one
tap, and a frontier model is worth having when there is signal.

## How it behaves

- **One model resident at a time.** Switching models unloads the previous one
  first. Nothing else reclaims 1.8 GB.
- **Requests are serialized.** llama.cpp keeps one context; two generations
  through it at once would corrupt both. A second request waits.
- **Thinking is off.** Qwen3.5 would otherwise spend several hundred tokens
  reasoning before answering, which at 20 tok/s is most of a minute of nothing.
- **GPU by default** — Metal on Apple, Vulkan on Android. CPU-only inference is
  several times slower and heats the phone.
- **The answer budget is 640 tokens.** Generation is the slow part, so this is a
  latency setting more than a quality one.
- **Tools and agent mode are not used.** A phone-sized model cannot drive a tool
  loop, and the scaffolding would eat the token budget.

## Why Qwen3.5 is faster than its size suggests

Qwen3.5 is a hybrid: most layers are state-space (the GGUF carries
`qwen35.ssm.*`), with full attention every fourth layer
(`full_attention_interval = 4`). The recurrent layers do not grow a KV cache and
are cheaper per token, so decode beats what a bandwidth estimate for a dense
model of the same size would predict.

## The package is vendored

`llm_llamacpp` is patched under `third_party/llm_llamacpp`; no iOS build of the
published package can succeed. See its `PATCH.md`.
