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
a few seconds. For Kokoro the list is the speaker ids the model exposes; for
`kokoro-multi-lang-v1_0`, speaker `45` is a Chinese female voice. Drop a
`voices.txt` in the model folder (one name per line, in speaker id order) to see
names instead of bare numbers.

The **rate** slider in the reading view is used as a speed multiplier, where
`1.0` is the model's natural pace. **Pitch** is ignored: these models do not
expose it.

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

Measured with `kokoro-multi-lang-v1_0` (float model, 2 threads) on an Apple
silicon Mac: the model loads in about 0.5 s and synthesis runs at 0.37–0.51×
real time, i.e. comfortably ahead of playback.

- Memory is the real constraint on mobile: prefer the int8 models.
- The first sentence pays for model loading.
- ZipVoice is heavier than Kokoro; raise **Threads** and keep the sampling
  steps low.

## Checking a model on a device

`integration_test/sherpa_tts_test.dart` loads the model, synthesizes a
bilingual sentence and writes `sherpa_tts_sample.wav` next to the app's data,
printing the load and synthesis times. It skips itself when no model is
installed.

```bash
flutter test integration_test/sherpa_tts_test.dart -d macos
```

## Limitations

- HarmonyOS (`ohos`) has no sherpa-onnx binary in the plugin, so the offline
  service is unavailable there.
- The Dart API of sherpa-onnx does not forward `dict_dir` for Kokoro, VITS and
  Matcha. Chinese Kokoro works through `lexicon-zh.txt`, which is what the
  official Kokoro example uses, but models that *require* a jieba dictionary
  need a patched `sherpa_onnx` package.
- Pitch control is not supported by these models.
