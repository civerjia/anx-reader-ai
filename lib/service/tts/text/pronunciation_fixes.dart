import 'package:anx_reader/service/tts/text/pronunciation_lexicon.dart';
import 'package:flutter/services.dart' show rootBundle;

/// A correction a listener made after hearing a word misread: the character
/// at [index] of [word] is read [reading], either marked on the character or
/// spoken as [homophone] when the mark sounded off.
class PronunciationFix {
  const PronunciationFix({
    required this.word,
    required this.index,
    required this.reading,
    this.homophone,
    this.useHomophone = false,
  });

  final String word;
  final int index;

  /// Pinyin with a tone number: lou4.
  final String reading;
  final String? homophone;
  final bool useHomophone;

  String get char => word[index];

  PronunciationFix copyWith({
    int? index,
    String? reading,
    String? homophone,
    bool? useHomophone,
  }) =>
      PronunciationFix(
        word: word,
        index: index ?? this.index,
        reading: reading ?? this.reading,
        homophone: homophone ?? this.homophone,
        useHomophone: useHomophone ?? this.useHomophone,
      );

  Map<String, Object?> toMap() => {
        'word': word,
        'index': index,
        'reading': reading,
        'homophone': homophone,
        'useHomophone': useHomophone,
      };

  static PronunciationFix? fromMap(Map<String, dynamic> map) {
    final word = map['word'];
    final index = map['index'];
    final reading = map['reading'];
    if (word is! String || index is! int || reading is! String) return null;
    if (index < 0 || index >= word.length) return null;
    return PronunciationFix(
      word: word,
      index: index,
      reading: reading,
      homophone: map['homophone'] as String?,
      useHomophone: map['useHomophone'] == true && map['homophone'] is String,
    );
  }
}

class PronunciationFixes {
  /// [text] with the homophone corrections spoken in place.
  static String rewrite(String text, List<PronunciationFix> fixes) {
    var result = text;
    for (final fix in fixes) {
      final homophone = fix.homophone;
      if (!fix.useHomophone || homophone == null) continue;
      final replaced = fix.word.replaceRange(fix.index, fix.index + 1, homophone);
      result = result.replaceAll(fix.word, replaced);
    }
    return result;
  }

  /// Marks for the corrections kept on the character.
  static List<PronunciationMark> marks(String text, List<PronunciationFix> fixes) => [
        for (final fix in fixes)
          if (!fix.useHomophone)
            for (var start = text.indexOf(fix.word);
                start >= 0;
                start = text.indexOf(fix.word, start + fix.word.length))
              PronunciationMark(start + fix.index, fix.reading),
      ];
}

/// Every CJK character's readings, how many listed words use each, and how
/// common the character is, from the bundled chars.txt.
class CharReadings {
  CharReadings.parse(String data) {
    for (final line in data.split('\n')) {
      final parts = line.split('\t');
      if (parts.length != 3 || parts[0].length != 1) continue;
      final char = parts[0];
      final readings = <String>[];
      final counts = <String, int>{};
      for (final item in parts[1].split(',')) {
        final colon = item.indexOf(':');
        final reading = colon < 0 ? item : item.substring(0, colon);
        readings.add(reading);
        counts[reading] = colon < 0 ? 0 : int.tryParse(item.substring(colon + 1)) ?? 0;
      }
      _readings[char] = readings;
      _counts[char] = counts;
      _uses[char] = int.tryParse(parts[2]) ?? 0;
    }
  }

  static const asset = 'assets/pronunciation/chars.txt';
  static Future<CharReadings>? _loading;

  static Future<CharReadings> load() => _loading ??=
      rootBundle.loadString(asset, cache: false).then(CharReadings.parse);

  final _readings = <String, List<String>>{};
  final _counts = <String, Map<String, int>>{};
  final _uses = <String, int>{};

  List<String> of(String char) => _readings[char] ?? const [];

  bool isPolyphonic(String char) =>
      of(char).where((r) => !r.endsWith('5')).length > 1;

  /// The reading most listed words use, if any word uses the character.
  String? usual(String char) {
    final counts = _counts[char];
    if (counts == null || counts.values.every((n) => n == 0)) return null;
    return counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  }

  /// Common characters that are read [reading] in nearly every word that
  /// uses them (漏 for lòu, not 长 for zhǎng), most used first.
  List<String> homophones(String reading, {String? except, int limit = 8}) {
    final found = <String>[];
    _counts.forEach((char, counts) {
      if (char == except) return;
      final total = counts.values.fold<int>(0, (sum, n) => sum + n);
      if (total == 0) return;
      if ((counts[reading] ?? 0) >= total * 0.95) found.add(char);
    });
    found.sort((a, b) => (_uses[b] ?? 0).compareTo(_uses[a] ?? 0));
    return found.take(limit).toList();
  }
}

const _toneMarks = {
  'a': ['ā', 'á', 'ǎ', 'à'],
  'e': ['ē', 'é', 'ě', 'è'],
  'i': ['ī', 'í', 'ǐ', 'ì'],
  'o': ['ō', 'ó', 'ǒ', 'ò'],
  'u': ['ū', 'ú', 'ǔ', 'ù'],
  'v': ['ǖ', 'ǘ', 'ǚ', 'ǜ'],
};

/// lou4 → lòu, lv4 → lǜ, de5 → de, for showing a reading.
String toneMarked(String reading) {
  final match = RegExp(r'^([a-z]+)([1-5])$').firstMatch(reading);
  if (match == null) return reading;
  final letters = match[1]!;
  final tone = int.parse(match[2]!);
  if (tone == 5) return letters.replaceAll('v', 'ü');
  // The mark goes on a or e, on the o of ou, else on the last vowel.
  int at;
  if (letters.contains('a')) {
    at = letters.indexOf('a');
  } else if (letters.contains('e')) {
    at = letters.indexOf('e');
  } else if (letters.contains('ou')) {
    at = letters.indexOf('o');
  } else {
    at = letters.lastIndexOf(RegExp(r'[iouv]'));
  }
  if (at < 0) return letters;
  final marked = _toneMarks[letters[at]]![tone - 1];
  return (letters.replaceRange(at, at + 1, marked)).replaceAll('v', 'ü');
}
