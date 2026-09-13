# flutter_tts, vendored

Copied from https://github.com/Anxcye/flutter_tts at
88d20d282354d6d211f15f721b9c43796edd1b68 (flutter_tts 4.2.3, MIT), without
`example/`, `.github/` and `.vscode/`.

Changed:

- `lib/flutter_tts.dart`: `speak` takes `pronunciations`, a list of
  `{start, length, notation}`; on iOS, when not empty, they are sent with the
  text.
- `ios/Classes/SwiftFlutterTtsPlugin.swift`: `speak` accepts that map as well
  as a plain string and builds the utterance from an attributed string with
  `AVSpeechSynthesisIPANotationAttribute` on each range.

Why: narration marks the reading of polyphonic characters. Measured on an
iPhone with the Yue (Premium) voice, a pinyin-with-tone-number notation
("zhao1") on the character is followed every time, while tone-mark pinyin is
ignored and IPA is unreliable.
