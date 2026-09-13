// Builds the pronunciation lexicon narration uses to mark polyphonic
// characters for the system voice.
//
//   dart run tool/pronunciation/build_lexicon.dart \
//     pinyin.txt zdic_cybs.txt 1985.md assets/pronunciation/lexicon.txt
//
// Sources, in rising precedence:
// - pinyin.txt: phrase-pinyin-data's reviewed word list (mozillazg, MIT),
//   https://github.com/mozillazg/phrase-pinyin-data
// - zdic_cybs.txt: the idiom list in the same repository, from zdic.net.
// - 1985.md: 普通话异读词审音表 (1985), the national standard for words with
//   disputed readings, as text from https://github.com/zispace/data-yiduci
//
// Chosen by measurement: on 50 idioms with well-known traps both lists were
// right on every one they had, where CC-CEDICT and mapull/chinese-dictionary
// were each wrong on four.
//
// Output, one word per line: the word alone when nothing in it needs a mark
// (kept so segmentation sees it), or the word, a tab and one reading per
// character, `_` for characters left to the voice. Readings are pinyin with
// a tone number, ü as v: 抛头露面\t_ _ lu4 _. Words the sources give more
// than one reading for carry no marks.
import 'dart:io';

const _marked = {
  'ā': ('a', 1), 'á': ('a', 2), 'ǎ': ('a', 3), 'à': ('a', 4),
  'ē': ('e', 1), 'é': ('e', 2), 'ě': ('e', 3), 'è': ('e', 4),
  'ī': ('i', 1), 'í': ('i', 2), 'ǐ': ('i', 3), 'ì': ('i', 4),
  'ō': ('o', 1), 'ó': ('o', 2), 'ǒ': ('o', 3), 'ò': ('o', 4),
  'ū': ('u', 1), 'ú': ('u', 2), 'ǔ': ('u', 3), 'ù': ('u', 4),
  'ǖ': ('v', 1), 'ǘ': ('v', 2), 'ǚ': ('v', 3), 'ǜ': ('v', 4),
  'ń': ('n', 2), 'ň': ('n', 3), 'ǹ': ('n', 4), 'ḿ': ('m', 2),
};

final _han = RegExp(r'^[一-鿿]+$');
final _syllable = RegExp(r'^[a-zü]+[1-5]$');

/// huán → huan2, huo → huo5, lǜ → lv4; null for anything else.
String? numbered(String pinyin) {
  var tone = 5;
  final letters = StringBuffer();
  for (final rune in pinyin.toLowerCase().replaceAll('ɡ', 'g').runes) {
    final c = String.fromCharCode(rune);
    final mark = _marked[c];
    if (mark != null) {
      letters.write(mark.$1);
      tone = mark.$2;
    } else if (c == 'ü') {
      letters.write('v');
    } else {
      letters.write(c);
    }
  }
  final result = '$letters$tone';
  return _syllable.hasMatch(result) ? result : null;
}

/// word → the distinct readings the list gives it.
Map<String, Set<String>> readWordList(File file) {
  final words = <String, Set<String>>{};
  for (var line in file.readAsLinesSync()) {
    line = line.split('#').first.trim();
    final colon = line.indexOf(':');
    if (colon < 0) continue;
    final word = line.substring(0, colon).trim();
    final syllables = line.substring(colon + 1).trim().split(RegExp(r'\s+'));
    if (!_han.hasMatch(word) || syllables.length != word.length) continue;
    final readings = syllables.map(numbered).toList();
    if (readings.contains(null)) continue;
    words.putIfAbsent(word, () => {}).add(readings.join(' '));
  }
  return words;
}

class Shenyin {
  /// Characters read one way in every word (统读), with the words excepted
  /// where the table says 除……外.
  final uniform = <String, String>{};
  final exceptions = <String, Map<String, String>>{};

  /// word → character → reading, for the example words the table lists.
  final words = <String, Map<String, String>>{};
  final ambiguous = <String>{};
}

final _readingLine = RegExp(
    r'^(?:（[一二三四五六七八]）)?\s*([a-zàáǎāèéěēìíǐīòóǒōùúǔūǖǘǚǜüńňǹḿ]+)');
final _quoted = RegExp(r'“([^”]+)”');

Shenyin readShenyin(File file) {
  final table = Shenyin();
  final text = file.readAsStringSync();
  final body = text.substring(text.indexOf('---'));
  final parts = body.split(RegExp(r'\n- \*\*(.+?)\*\*\n'));
  final heads = RegExp(r'\n- \*\*(.+?)\*\*\n')
      .allMatches(body)
      .map((m) => m[1]!)
      .toList();

  void addWord(String word, String head, String reading) {
    if (!_han.hasMatch(word) || !word.contains(head)) return;
    final known = table.words[word]?[head];
    if (known != null && known != reading) {
      table.ambiguous.add(word);
      return;
    }
    table.words.putIfAbsent(word, () => {})[head] = reading;
  }

  for (var k = 0; k < heads.length; k++) {
    final head = heads[k];
    final block = parts[k + 1]
        .split('\n')
        .where((l) => !l.startsWith('#'))
        .join('\n')
        .trim();
    final first = numbered(_readingLine.firstMatch(block)?[1] ?? '');

    if (block.contains('统读')) {
      if (first != null) table.uniform[head] = first;
      continue;
    }

    final except = RegExp(r'除(.+?)(?:读|念)([a-zàáǎāèéěēìíǐīòóǒōùúǔūǖǘǚǜü]+)(?:之)?外');
    final exceptMatch = except.firstMatch(block);
    if (exceptMatch != null) {
      final special = numbered(exceptMatch[2]!);
      final rest = RegExp(r'都(?:读|念)([a-zàáǎāèéěēìíǐīòóǒōùúǔūǖǘǚǜü]+)').firstMatch(block);
      final usual = rest != null ? numbered(rest[1]!) : first;
      if (special == null || usual == null) continue;
      if (_quoted.allMatches(exceptMatch[1]!).isEmpty) continue; // 除姓氏…
      table.uniform[head] = usual;
      final words = table.exceptions.putIfAbsent(head, () => {});
      for (final q in _quoted.allMatches(exceptMatch[1]!)) {
        words[q[1]!.replaceAll('～', head)] = special;
      }
      continue;
    }

    String? reading;
    for (final line in block.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final readingMatch = _readingLine.firstMatch(trimmed);
      if (readingMatch != null &&
          (trimmed.startsWith('（') && RegExp(r'^（[一二三四五六七八]）').hasMatch(trimmed) ||
              !trimmed.contains('～'))) {
        final r = numbered(readingMatch[1]!);
        if (r != null) {
          reading = r;
          continue;
        }
      }
      if (reading == null) continue;
      final candidates = <String>[
        for (final q in _quoted.allMatches(trimmed)) q[1]!,
        ...trimmed
            .replaceAll(_quoted, ' ')
            .replaceAll(RegExp(r'（[^）]*）|\([^)]*\)'), ' ')
            .split(RegExp(r'[\s，。、；：]+')),
      ];
      for (final candidate in candidates) {
        if (!candidate.contains('～')) continue;
        final word = candidate
            .replaceAll(RegExp(r'（[^）]*）|\([^)]*\)'), '')
            .replaceAll('～', head);
        addWord(word, head, reading);
      }
    }
  }
  for (final word in table.ambiguous) {
    table.words.remove(word);
  }
  return table;
}

void main(List<String> args) {
  if (args.length != 4) {
    stderr.writeln('usage: build_lexicon.dart pinyin.txt zdic_cybs.txt 1985.md output');
    exit(64);
  }
  final words = readWordList(File(args[0]));
  final idioms = readWordList(File(args[1]));
  final shenyin = readShenyin(File(args[2]));

  final readings = <String, Set<String>>{};
  for (final source in [words, idioms]) {
    source.forEach((word, r) => readings.putIfAbsent(word, () => {}).addAll(r));
  }

  // A character is polyphonic when the sources read it more than one way,
  // neutral tones aside.
  final sounds = <String, Set<String>>{};
  readings.forEach((word, set) {
    for (final reading in set) {
      final syllables = reading.split(' ');
      for (var i = 0; i < word.length; i++) {
        if (!syllables[i].endsWith('5')) {
          sounds.putIfAbsent(word[i], () => {}).add(syllables[i]);
        }
      }
    }
  });
  bool polyphonic(String char) => (sounds[char]?.length ?? 0) > 1;

  // How many words read each character each way: the most common reading
  // is what the voice falls back on, and it was heard to misread only the
  // rarer ones (朝阳 zhāo, 曾家 zēng, 露了一手 lòu).
  final counts = <String, Map<String, int>>{};
  readings.forEach((word, set) {
    if (set.length != 1) return;
    final syllables = set.single.split(' ');
    for (var i = 0; i < word.length; i++) {
      final byReading = counts.putIfAbsent(word[i], () => {});
      byReading[syllables[i]] = (byReading[syllables[i]] ?? 0) + 1;
    }
  });
  String? usual(String char) {
    final byReading = counts[char];
    if (byReading == null || byReading.isEmpty) return null;
    final sorted = byReading.entries.toList()..sort((a, b) => b.value - a.value);
    if (sorted.length > 1 && sorted[0].value == sorted[1].value) return null;
    return sorted.first.key;
  }

  final shenyinWords = {...shenyin.words.keys, for (final e in shenyin.exceptions.values) ...e.keys};

  /// Whether a reading has to be marked for the voice to say it.
  bool needsMark(String word, List<String> syllables, int i) {
    final reading = syllables[i];
    if (reading == '_' || reading.endsWith('5')) return false;
    // 一 and 不 change tone with what follows; the voice does that itself.
    if (word[i] == '一' || word[i] == '不') return false;
    // A third tone before a third tone is said rising; a fixed mark would
    // stop the voice from doing so.
    if (reading.endsWith('3') && i + 1 < word.length && syllables[i + 1].endsWith('3')) {
      return false;
    }
    return shenyinWords.contains(word) || reading != usual(word[i]);
  }

  final out = <String, List<String>?>{};
  var fromTable = 0;
  readings.forEach((word, set) {
    if (set.length != 1) {
      out[word] = null;
      return;
    }
    final syllables = set.single.split(' ');
    out[word] = [
      for (var i = 0; i < word.length; i++)
        polyphonic(word[i]) && needsMark(word, syllables, i) ? syllables[i] : '_',
    ];
  });

  String? shenyinReading(String word, int i) {
    final char = word[i];
    final listed = shenyin.words[word]?[char];
    if (listed != null) return listed;
    final excepted = shenyin.exceptions[char]?[word];
    if (excepted != null) return excepted;
    return shenyin.uniform[char];
  }

  // The standard overrides the lists wherever it speaks: its example words,
  // its exceptions, and characters it reads one way everywhere.
  for (final word in shenyinWords) {
    out.putIfAbsent(word, () => List.filled(word.length, '_'));
  }
  out.forEach((word, marks) {
    for (var i = 0; i < word.length; i++) {
      final standard = shenyinReading(word, i);
      if (standard == null) continue;
      final listed = marks?[i];
      // Only where the standard decides between readings: a listed neutral
      // tone stays with the voice.
      if (listed == standard) continue;
      if (marks == null) {
        if (!shenyin.words.containsKey(word)) continue;
        out[word] = marks = List.filled(word.length, '_');
      }
      // Elsewhere only where the lists read it another way.
      if (listed == '_' && !shenyinWords.contains(word)) continue;
      if (word[i] == '一' || word[i] == '不') continue;
      marks[i] = standard;
      fromTable++;
    }
  });

  final lines = out.keys.toList()..sort();
  final buffer = StringBuffer();
  var marked = 0;
  for (final word in lines) {
    final marks = out[word];
    if (marks == null || marks.every((m) => m == '_')) {
      buffer.writeln(word);
    } else {
      buffer.writeln('$word\t${marks.join(' ')}');
      marked++;
    }
  }
  File(args[3])
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(buffer.toString());
  stdout.writeln('${lines.length} words, $marked with marks, '
      '$fromTable marks set by the 审音表 '
      '(${shenyin.words.length} example words, ${shenyin.uniform.length} uniform characters, '
      '${shenyin.exceptions.length} with exceptions, ${shenyin.ambiguous.length} ambiguous)');
}
