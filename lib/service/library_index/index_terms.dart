/// Search terms for the library index.
///
/// SQLite's tokenizers treat a run of Chinese characters as a single word, so
/// the text is broken up here instead: every pair of adjacent CJK characters is
/// a term (a single character standing alone is one too), and runs of Latin
/// letters or digits are words. Pairs find two-character names such as 赫萝 and
/// any longer phrase, without a dictionary or a model.
library;

bool isCjkRune(int r) =>
    (r >= 0x3400 && r <= 0x9FFF) || // unified han, extension A
    (r >= 0xF900 && r <= 0xFAFF) || // compatibility ideographs
    (r >= 0x3040 && r <= 0x30FF) || // kana
    (r >= 0xAC00 && r <= 0xD7AF) || // hangul
    (r >= 0x20000 && r <= 0x2FA1F); // extensions B-F

bool _isWordRune(int r) =>
    (r >= 0x30 && r <= 0x39) ||
    (r >= 0x41 && r <= 0x5A) ||
    (r >= 0x61 && r <= 0x7A) ||
    (r >= 0xC0 && r <= 0x24F);

Iterable<String> _terms(String text, {required bool singles}) sync* {
  final cjk = <int>[];
  final word = StringBuffer();
  Iterable<String> flushCjk() sync* {
    if (cjk.length == 1) {
      if (singles) yield String.fromCharCode(cjk.first);
    } else {
      for (var i = 0; i + 1 < cjk.length; i++) {
        yield String.fromCharCodes([cjk[i], cjk[i + 1]]);
      }
    }
    cjk.clear();
  }

  Iterable<String> flushWord() sync* {
    if (word.length >= 2) yield word.toString().toLowerCase();
    word.clear();
  }

  for (final r in text.runes) {
    if (isCjkRune(r)) {
      yield* flushWord();
      cjk.add(r);
    } else if (_isWordRune(r)) {
      yield* flushCjk();
      word.writeCharCode(r);
    } else {
      yield* flushCjk();
      yield* flushWord();
    }
  }
  yield* flushCjk();
  yield* flushWord();
}

/// Distinct terms of an indexed passage, space-separated for the tokenizer.
/// A lone CJK character is left out: queries of one character match by prefix.
String indexTermsOf(String text) => _terms(text, singles: false).toSet().join(' ');

/// The terms of a query, in order and without repeats.
List<String> queryTermsOf(String query) =>
    _terms(query, singles: true).toSet().toList();

/// [text] lowercased with everything but letters, digits and CJK removed, for
/// checking whether a passage holds a query as a whole phrase.
String squashed(String text) {
  final out = StringBuffer();
  for (final r in text.runes) {
    if (isCjkRune(r)) {
      out.writeCharCode(r);
    } else if (_isWordRune(r)) {
      out.write(String.fromCharCode(r).toLowerCase());
    }
  }
  return out.toString();
}
