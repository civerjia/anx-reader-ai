**English** | [简体中文](README_zh.md)

<p align="center">
  <img src="./docs/images/Anx-logo.jpg" alt="logo" width="100" />
</p>
<h1 align="center">Anx Reader — AI fork</h1>

A personal fork of [Anxcye/anx-reader](https://github.com/Anxcye/anx-reader), an
e-book reader built with Flutter. Everything here is written for the way I read:
Chinese books on an iPhone, offline, with a model that runs on the phone rather
than in someone's cloud. The upstream project is where releases and support come
from; this fork is built from source and carries no binaries.

What follows is what this fork adds. Everything else — the shelf, the EPUB
engine, syncing, statistics — is upstream's work.

## A page curl that behaves like paper

- The page is picked up where the finger touches it and bends around a cylinder,
  following the finger until it is let go; turning back rolls the previous page
  up from the left and unrolls it under the finger.
- The back of the sheet is paper, with the print showing faintly through it and
  a grain of its own: cloudy unevenness from several octaves of Perlin noise,
  plus hairline fibres. The front takes the grain only where it lifts, so the
  part still lying flat matches the live page underneath.
- Through a run of turns the page keeps up: a new drag takes the page over from
  one still settling, the settle itself shortens, snapshots are taken at half
  width, and the page the turn lands on is captured while the curl finishes, so
  the next turn has it in hand. Measured on the phone: about 500 ms a page
  before, 190–340 ms after.
- Sliding turns snap with the native scroller, and every turn logs where its
  time went, which is how all of the above was measured rather than guessed.

## A model that runs on the phone

- llama.cpp is vendored and built here (`third_party/llm_llamacpp`,
  `tool/build_llamacpp_apple.sh`) because the published build could not load on
  iOS and predates the architectures worth running.
- Spark-X2.5 support: the architecture needs llama.cpp b10950, llama.cpp has no
  chat template for it, so the prompt is rendered in Dart to the model's own
  format, and its `<arg_key>/<arg_value>` tool calls are parsed as their own
  format. MiniCPM5's XML calls are recognised too.
- The conversation is fitted to the context that is actually loaded — long
  earlier turns are shortened, then dropped — instead of failing the whole
  request once it overflows.
- The model is told which book is open, with its id. Thinking is a switch, and
  what the model reasons goes to a thinking panel rather than into the answer.
  A button unloads the weights from memory, since 1.8 GB resident makes the
  phone sluggish between the occasional questions.

## Searching the library, not just the open book

- Every EPUB is read in Dart — spine order, titles from the nav document or the
  NCX — split into passages of about a thousand characters and indexed in a
  database of its own: Chinese as adjacent character pairs, Latin as words, in a
  contentless FTS5 table that stores only each passage's book, document and
  character range. The text is read back from the book for the passages a search
  returns.
- Measured on a 5.27-million-character novel: 0.8 s to read, 1.9 s to index,
  7.2 MB of index, searches in 25–57 ms.
- The AI gets a `library_search` tool over it; in-book search gained a button in
  the reader, an item in the selection menu, and a message when nothing matches.

## Knowing things without a network

- Offline Wikipedia: ZIM packs on the device, a catalogue to pick them from, and
  a lookup tool the model is told to use before stating a fact.
- Offline dictionaries: StarDict dictionaries for a selected word, a bundled
  English-Chinese dictionary, and iOS's own dictionaries before any online
  translation.

## Narration that reads Chinese properly

- Numbers, powers of ten, `No.`, units and counts are rewritten before they
  reach the system voice; chemical formulas are named (H₃O⁺ as 水合氢离子,
  Na₂HPO₄ as 磷酸氢二钠) unless the sentence already names them.
- Misread polyphones are marked with pinyin and tone, with a homophone where a
  mark sounds wrong (露富, 女红). There is a pronunciation test page, and a
  panel to correct a word the moment you hear it read wrong.
- Narration resumes on the sentence it stopped on; the lock screen skips thirty
  seconds.

## Shelf, notes, PDF

- Series from EPUB metadata: sorted, gathered into folders, volumes ordered by
  the numbers or Roman numerals in their titles. Several books can be selected
  and moved into a folder at once.
- Dissolving a folder is behind edit mode and a confirmation; notes can be
  deleted from the notes page by swiping; the import dialog ticks books only
  once they are in and closes itself when they all are.
- OPDS catalogues can be browsed and books downloaded from them.
- PDF: highlights and notes, trimmed margins, pinch zoom, the same page-turn
  styles as EPUB.

## Staying where you were

- iOS reclaims the web process of an app left in the background; the reader now
  reloads itself at the reading position instead of coming back white.
- A launch after iOS has killed the app reopens the book that was open.

## Building

Flutter, as upstream. The one extra step is the native library for the local
model, which is not committed:

```sh
cd third_party/llm_llamacpp && sh tool/build_llamacpp_apple.sh
```

GGUF weights go in the app's `Documents/llm_models/`.

## Licence

MIT, as upstream — see [LICENSE](LICENSE), whose copyright stays with the
original author.
