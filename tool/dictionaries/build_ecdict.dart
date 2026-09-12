// Builds the bundled English-Chinese dictionary from ECDICT.
//
//   dart run tool/dictionaries/build_ecdict.dart ecdict.csv LICENSE assets/dictionaries/ecdict
//
// (ecdict.csv and LICENSE from the ECDICT repository.)
//
// ECDICT (https://github.com/skywind3000/ECDICT) is MIT-licensed. The bundled
// edition keeps the words a reader is likely to meet: those on the Collins,
// Oxford 3000 or exam word lists, or within the 50,000 most frequent words of
// the BNC or the contemporary corpus. Inflected forms from its exchange field
// become synonyms, so "went" finds "go".
import 'dart:convert';
import 'dart:io';

import 'stardict_writer.dart';

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    stderr.writeln('usage: build_ecdict.dart ecdict.csv LICENSE output-folder');
    exit(64);
  }
  final out = Directory(args[2])..createSync(recursive: true);
  final source = StarDictSource(
    name: 'ECDICT 英汉词典（常用词）',
    description: 'ECDICT by skywind3000, MIT License. '
        'Common-words edition built for Anx Reader: Collins, Oxford 3000 and exam '
        'word lists plus the 50,000 most frequent words of the BNC and contemporary corpus.',
    author: 'skywind3000',
    website: 'https://github.com/skywind3000/ECDICT',
    // One text field, with the phonetic as its first line: readers that only
    // handle single-field entries (foliate's among them) can read it too.
    sameTypeSequence: 'm',
  );

  List<String>? header;
  var rows = 0;
  await for (final row in readCsv(File(args[0]))) {
    if (header == null) {
      header = row;
      continue;
    }
    rows++;
    final o = {for (var i = 0; i < header.length; i++) header[i]: i < row.length ? row[i] : ''};
    final translation = o['translation']!.replaceAll(r'\n', '\n').trim();
    if (translation.isEmpty) continue;
    final collins = int.tryParse(o['collins']!) ?? 0;
    final bnc = int.tryParse(o['bnc']!) ?? 0;
    final frq = int.tryParse(o['frq']!) ?? 0;
    final keep = collins > 0 ||
        o['oxford'] == '1' ||
        o['tag']!.trim().isNotEmpty ||
        (bnc > 0 && bnc <= 50000) ||
        (frq > 0 && frq <= 50000);
    if (!keep) continue;
    final word = o['word']!.trim();
    if (word.isEmpty || source.entries.containsKey(word)) continue;
    final phonetic = o['phonetic']!.trim();
    source.entries[word] =
        utf8.encode(phonetic.isEmpty ? translation : '/$phonetic/\n$translation');
    // exchange: p past, d past participle, i -ing, 3 third person, r
    // comparative, t superlative, s plural; 0 and 1 describe this word's own
    // lemma and are not forms of it.
    for (final item in o['exchange']!.split('/')) {
      final colon = item.indexOf(':');
      if (colon != 1) continue;
      final kind = item[0];
      final form = item.substring(2).trim();
      if ('pdi3rts'.contains(kind) && form.isNotEmpty && form != word) {
        source.synonyms.putIfAbsent(form, () => word);
      }
    }
  }
  final sizes = writeStarDict(source, '${out.path}/ecdict');
  // Upstream's own LICENSE file, copied as it is.
  File(args[1]).copySync('${out.path}/LICENSE.txt');
  stdout.writeln('rows read: $rows; entries: ${source.entries.length}; '
      'synonyms offered: ${source.synonyms.length}; files: $sizes');
}
