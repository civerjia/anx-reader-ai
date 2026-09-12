# Why this package is vendored

`OfflineTts` builds the native config field by field, and three of them are
missed: `dictDir` for the vits, matcha and kokoro families. The field exists
in the Dart config class and in the native struct, but nothing copies one to
the other, so any model that needs a jieba dictionary cannot be loaded from
Flutter at all. That rules out the better Chinese models, among them
`vits-melo-tts-zh_en` and `matcha-icefall-zh-baker`.

The patch is three assignments and the three matching `calloc.free` calls in
`lib/src/tts.dart`, against sherpa_onnx 1.13.8. Drop this directory and the
`dependency_overrides` entry once upstream carries the fix.
