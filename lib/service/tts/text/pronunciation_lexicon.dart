import 'dart:math' as math;

import 'package:flutter/services.dart' show rootBundle;

/// A reading to attach to one character of a sentence.
class PronunciationMark {
  const PronunciationMark(this.start, this.notation);

  /// UTF-16 index of the character.
  final int start;

  /// Pinyin with a tone number, as the system voice takes it: lu4.
  final String notation;
}

/// Words with the reading of their polyphonic characters, built by
/// tool/pronunciation/build_lexicon.dart from the 1985 审音表, an idiom list
/// and a reviewed word list. Sentences are split into the longest words the
/// lexicon knows; a word is marked only when no other word crosses its edges
/// (在行走 is 在 + 行走, not 在行 + 走) and the lexicon gives it one reading.
class PronunciationLexicon {
  PronunciationLexicon.parse(String data) {
    for (final line in data.split('\n')) {
      if (line.isEmpty) continue;
      final tab = line.indexOf('\t');
      final word = tab < 0 ? line : line.substring(0, tab);
      _words[word] = tab < 0 ? null : line.substring(tab + 1).split(' ');
      _maxLength = math.max(_maxLength, word.length);
    }
  }

  static const asset = 'assets/pronunciation/lexicon.txt';
  static Future<PronunciationLexicon>? _loading;
  static PronunciationLexicon? _loaded;

  /// The lexicon once [load] has finished, else null.
  static PronunciationLexicon? get loaded => _loaded;

  static Future<PronunciationLexicon> load() => _loading ??= rootBundle
      .loadString(asset, cache: false)
      .then((data) => _loaded = PronunciationLexicon.parse(data));

  /// How ü is written for the voice; null leaves syllables with ü unmarked
  /// until a notation for it is confirmed by ear.
  static String? umlaut;

  static final _han = RegExp(r'[一-鿿]+');

  final Map<String, List<String>?> _words = {};
  int _maxLength = 1;

  int get length => _words.length;

  List<PronunciationMark> marks(String text) {
    final result = <PronunciationMark>[];
    for (final run in _han.allMatches(text)) {
      final chunk = run[0]!;
      var i = 0;
      while (i < chunk.length) {
        var matched = 1;
        for (var len = math.min(_maxLength, chunk.length - i); len >= 2; len--) {
          if (_words.containsKey(chunk.substring(i, i + len))) {
            matched = len;
            break;
          }
        }
        if (matched > 1) {
          final readings = _words[chunk.substring(i, i + matched)];
          if (readings != null && !_crosses(chunk, i, i + matched)) {
            for (var k = 0; k < matched; k++) {
              final notation = _notation(readings[k]);
              if (notation != null) {
                result.add(PronunciationMark(run.start + i + k, notation));
              }
            }
          }
        }
        i += matched;
      }
    }
    return result;
  }

  /// Whether a word the lexicon knows crosses either edge of text[s, e).
  bool _crosses(String text, int s, int e) {
    for (var j = s + 1; j < e; j++) {
      for (var k = e + 1; k <= math.min(text.length, j + _maxLength); k++) {
        if (_words.containsKey(text.substring(j, k))) return true;
      }
    }
    for (var j = math.max(0, s - _maxLength + 1); j < s; j++) {
      for (var k = s + 1; k < e; k++) {
        if (k - j >= 2 && _words.containsKey(text.substring(j, k))) return true;
      }
    }
    return false;
  }

  static String? _notation(String reading) {
    // Neutral tones (shi5 in 钥匙) have no notation confirmed by ear.
    if (reading == '_' || reading.endsWith('5')) return null;
    if (!reading.contains('v')) return reading;
    final u = umlaut;
    return u == null ? null : reading.replaceAll('v', u);
  }
}
