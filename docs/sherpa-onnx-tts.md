# Offline TTS with sherpa-onnx

Anx can read books aloud with [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)
models that run entirely on the device. No API key, no network, no per character
billing. Supported families:

| Family | What it is | Speaker selection |
| --- | --- | --- |
| **Kokoro** | Multi speaker neural TTS, `kokoro-multi-lang-v1_0` speaks Chinese and English | speaker id |
| **ZipVoice** | Zero shot voice cloning from a few seconds of reference audio | cloned from the reference wave |
| **VITS / Piper** | The classic sherpa-onnx / Piper voices | speaker id |
| **Matcha** | Flow matching acoustic model plus a vocoder | speaker id |
| **Kitten** | Small English models | speaker id |

## 1. Get a model

Models live in the sherpa-onnx release pages. Download one archive and unpack it;
the folder you unpack is what Anx points at.

```bash
# Kokoro, Chinese + English, 53 speakers (~330 MB)
curl -SLO https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-multi-lang-v1_0.tar.bz2
tar xf kokoro-multi-lang-v1_0.tar.bz2

# ZipVoice, Chinese + English voice cloning (int8, smaller and faster)
curl -SLO https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/sherpa-onnx-zipvoice-distill-int8-zh-en-emilia.tar.bz2
tar xf sherpa-onnx-zipvoice-distill-int8-zh-en-emilia.tar.bz2

# ZipVoice needs a vocoder, which ships separately.
# Put it inside the model folder so Anx finds it on its own.
curl -SL -o sherpa-onnx-zipvoice-distill-int8-zh-en-emilia/vocos_24khz.onnx \
  https://github.com/k2-fsa/sherpa-onnx/releases/download/vocoder-models/vocos_24khz.onnx
```

More models: <https://k2-fsa.github.io/sherpa/onnx/tts/index.html>

## 2. Put the model where the app can read it

Anx accepts an absolute path, or a folder name that it looks up under
`tts_models` in the app's documents directory:

| Platform | Where to put `tts_models/<model folder>` |
| --- | --- |
| macOS, Windows, Linux, Android | anywhere; pick the folder with the **Model folder** button |
| iOS, iPadOS | the app's *Documents* folder (Finder → iPhone → Files → Anx, or the Files app), then type just the folder name in settings |

Typing the plain folder name is also the most robust option on macOS: a path
picked outside the sandbox is not guaranteed to stay readable after a restart.

## 3. Configure Anx

**Settings → Narrate → TTS service → sherpa-onnx (offline)**

- **Model family** – Kokoro, ZipVoice, VITS/Piper, Matcha or Kitten.
- **Model folder** – the unpacked folder. Everything inside it (`model.onnx`,
  `voices.bin`, `tokens.txt`, `espeak-ng-data/`, `lexicon*.txt`, …) is detected
  automatically.
- **Vocoder** – only for ZipVoice and Matcha, and only when the vocoder file is
  not inside the model folder.
- **Reference audio / Reference text** – ZipVoice only. A 3–10 second wave file
  of the voice to clone plus the exact text spoken in it. Most ZipVoice archives
  ship examples in `test_wavs/`.
- **Sampling steps** – ZipVoice only. 4 is a good default for the distilled
  models; higher is slightly better and slower.
- **Threads** – CPU threads for inference. 2 on a phone, 4 or more on a desktop.
- **Prefer quantized models** – use the `*.int8.onnx` file when the folder ships
  both. Faster and much smaller, with a small quality cost.
- **Lexicon files** – optional override, comma separated.

Then press **Get voice list**. This loads the model, so the first press can take
a few seconds.

Voice names come from the model's own ONNX metadata (`speaker_names`), which is
how a multi speaker model records which id is which voice. Kokoro and Kitten
name theirs `<language><gender>_<name>`, so the list is grouped by language:
`kokoro-multi-lang-v1_0` puts its eight Chinese voices (`zf_xiaobei` … 
`zm_yunyang`, ids 45–52) under 中文 and the twenty American English ones under
English. A `voices.txt` in the model folder (one name per line, in speaker id
order) overrides this.

The **rate** slider in the reading view is used as a speed multiplier, where
`1.0` is the model's natural pace. **Pitch** is ignored: these models do not
expose it.

Two settings are worth knowing about:

- **Pause length** keeps the pauses inside a sentence as the model produced
  them. sherpa-onnx otherwise shrinks them to a fifth, and since it decides
  what counts as a pause by loudness alone, the quiet tail of the syllable
  before a comma is compressed away with it: one Chinese sentence with three
  commas loses a third of its audio, and every comma sounds like a swallowed
  word. Lower it only if you want a brisker read and can live with that.
- **Compute backend** picks between the CPU and the platform's neural
  accelerator. See the performance notes below.

Symbols the model's lexicon does not know are rewritten before synthesis:
Kokoro turns an unknown character into `❓`, which is not in its token table,
so `1%` would otherwise be read as `1` or, in a short sentence, not at all.
Percentages, degrees, currency and a few operators become words, with the
number moving behind the word for Chinese (`1%` to `百分之1`).

Two things in the folder are picked up without any setting:

- `*.fst` text normalisation rules (`date-zh.fst`, `phone-zh.fst`,
  `number-zh.fst` ship with the Chinese models) are applied in that order, so
  "2026 年" and phone numbers are read as words rather than digits.
- When a model carries both a US and a GB English lexicon, only the US one is
  loaded; sherpa-onnx keeps the first pronunciation it reads and warns about
  every duplicate. Set **Lexicon files** to override.

## 中文快速上手

1. 下载并解压模型（上面的命令），ZipVoice 记得把 `vocos_24khz.onnx` 放进模型文件夹。
2. 把模型文件夹放到任意位置（iOS 放到 App 的 Documents/tts_models 下）。
3. 设置 → 朗读 → TTS 服务 → 选择 **sherpa-onnx（离线）**。
4. 选择模型类型，指定模型文件夹；ZipVoice 还需要填参考音频和参考文本。
5. 点击"获取语音列表"，选一个说话人（`kokoro-multi-lang-v1_0` 的 45 是中文女声）。

## What the audio goes through

Between the model and the speaker, each sentence gets three things, all of
which came out of listening on a phone rather than reading numbers:

- **Pauses trimmed.** Kokoro leaves gaps of nearly a second at commas: five
  of them made up 40% of one nine second sentence. sherpa-onnx can shorten
  them itself but calls anything below 0.01 amplitude silence, which is
  where the tail of the word before the comma still sounds, so it eats word
  endings. Anx trims with a threshold of 0.002, keeping 60 to 100ms more of
  each word, and leaves gaps under 0.18s alone. **Pause length** controls
  how much is kept.
- **Loudness matched.** Every sentence is measured with ITU-R BS.1770 and
  brought to -23 LUFS with a single gain, capped so peaks are never
  reshaped. Both halves of that matter: average level is not loudness, and
  a soft knee that squashes loud syllables while leaving quiet ones alone
  is heard as the volume wandering inside a sentence. The target is low
  enough that no sentence has to stop short of it, because a difference is
  audible well under a decibel.
- **Speed split.** The model handles up to 1.25x, where it still re-times
  speech cleanly; past that it starts slurring and dropping the syllable
  before a pause, so the rest comes from the player, which resamples with
  the pitch kept. The rate slider reads as a plain multiplier: 2.0 is twice
  normal, whatever backend is speaking.

## How it works

- `lib/service/tts/sherpa/sherpa_model.dart` resolves a folder into concrete
  file paths for the chosen family.
- `lib/service/tts/sherpa/sherpa_tts_engine.dart` keeps one background isolate
  holding the loaded model. Inference is a blocking native call, so it must not
  run on the UI isolate, and one isolate also serialises the requests the
  sentence prefetcher makes.
- `lib/service/tts/sherpa/sherpa_tts_backend.dart` is a normal
  `TtsServiceProvider`: it returns wave bytes per sentence, so the existing
  buffering, highlighting and media controls work unchanged.

The model stays loaded until the TTS service is switched or the reader releases
TTS; changing any model setting reloads it on the next sentence.

## Performance notes

Real time factor (seconds of compute per second of audio, so lower is
better) on the same Chinese paragraph, 2 threads, Apple silicon Mac:

| Model | Size | RTF | Notes |
| --- | --- | --- | --- |
| `kokoro-multi-lang-v1_0` | 350 MB | 0.44–0.50 | 8 Chinese voices, all graded D |
| `kokoro-int8-multi-lang-v1_0` | 132 MB | 1.07–1.21 | same voices, much slower |
| `kokoro-int8-multi-lang-v1_1` | 147 MB | 0.99–1.04 | far better Chinese, 103 voices |
| `vits-zh-aishell3` | 116 MB | 0.39–0.49 | native Chinese, but only 8 kHz |
| `sherpa-onnx-zipvoice-distill-int8-zh-en-emilia` | 109 MB | 0.49–0.58 | 24 kHz voice cloning |

On the device itself, reading a book on an iPhone 16 Pro with
`kokoro-multi-lang-v1_1`:

| Backend | RTF | Note |
| --- | --- | --- |
| CoreML | 0.65 | the default on iOS |
| CPU | 0.58 | cold phone |
| CPU | 1.41 | warm phone, after ten minutes of reading |

The CPU throttles as the phone heats up, and once the RTF passes 1.0 the
prefetch buffer drains and every sentence waits on the model, which is heard
as a stutter every few sentences. CoreML holds its pace and runs cooler.
sherpa-onnx compiles the CoreML provider into its iOS binary only; on macOS
it logs `CoreML is for Apple only ... Fallback to cpu!` and runs on the CPU.

**Quantized is not the fast one here.** onnxruntime's int8 kernels on Apple
silicon run the Kokoro graph roughly 2.4× slower than the float model, so the
int8 downloads buy disk space, not speed. Pick by RTF first: anything under
about 0.6 stays comfortably ahead of playback, and the sentence prefetcher
absorbs the rest.

- The first sentence pays for model loading (about 0.5 s).
- ZipVoice is heavier than Kokoro; raise **Threads** and keep the sampling
  steps low.
- Anx logs one `SherpaTts <model>: …ms for …s of audio (RTF …)` line per
  model, so the number for your own device is in the app log.

## Checking a model on a device

`integration_test/sherpa_tts_test.dart` loads the model, synthesizes a
bilingual sentence and writes `sherpa_tts_sample.wav` next to the app's data,
printing the load and synthesis times. It skips itself when no model is
installed.

```bash
flutter test integration_test/sherpa_tts_test.dart -d macos
```

## Building this fork

Codegen is broken on the current upstream tip, for a reason that has nothing
to do with this feature: `v1.15.0-alpha.21` added `forui ^0.26.0`, which
requires Dart 3.13, while `riverpod_generator 2.x` / `custom_lint 0.7.x` pin
`analyzer ^7`, and that analyzer cannot serialize Dart 3.13 syntax. So
`dart run build_runner build` dies with
`Missing implementation of visitDotShorthandPropertyAccess` and no `.g.dart`
is produced. Upstream's own CI for alpha.21 never completed either.

Until that is resolved upstream (riverpod 4 brings `analyzer >=13`), the
offline TTS work was verified on a branch rebased onto the last green tag:

```bash
git checkout run/alpha20-sherpa   # v1.15.0-alpha.20 + this feature
dart run build_runner build --delete-conflicting-outputs
flutter test integration_test/sherpa_tts_test.dart -d macos
```

Building the macOS app locally also needs your own signing identity; the
Debug configuration in `macos/Runner.xcodeproj` points at the upstream team.

## Keeping ahead of playback

Synthesis has to produce audio faster than it is consumed, so at a playback
rate of P the RTF must stay below 1/P. Reading at 2x therefore needs RTF
below 0.5; when it is not, the prefetch buffer drains and every sentence
waits on the model, which is heard as a stutter every few sentences. The
log shows the buffer emptying: `TTS gap 13ms ... buffer 4`, then 3, 2, 1, 0.

Threads are the lever that works. On an iPhone 16 Pro reading a book,
Kokoro on two threads holds RTF 0.38 cold and 1.41 once the phone is warm;
the default is two threads short of the machine's core count, capped at
four. CoreML is not the lever: it took 0.54 against the CPU's 0.38 on the
same model, because Kokoro's input length changes with every sentence and
CoreML only takes the part of the graph it can shape.

## Limitations

- HarmonyOS (`ohos`) has no sherpa-onnx binary in the plugin, so the offline
  service is unavailable there.
- The Dart API of sherpa-onnx does not forward `dict_dir` for Kokoro, VITS and
  Matcha. Chinese Kokoro works through `lexicon-zh.txt`, which is what the
  official Kokoro example uses, but models that *require* a jieba dictionary
  need a patched `sherpa_onnx` package.
- Pitch control is not supported by these models.
- Kokoro speaks Chinese through `lexicon-zh.txt` rather than a Chinese G2P, so
  its Mandarin has a noticeable accent. For Chinese, ZipVoice with a Chinese
  reference clip sounds considerably more natural, and `vits-zh-aishell3` is
  natively Chinese but only 8 kHz. The nicer Chinese models
  (`vits-melo-tts-zh_en`, `matcha-icefall-zh-baker`) need `dict_dir`, which the
  sherpa-onnx Dart API does not forward yet.
