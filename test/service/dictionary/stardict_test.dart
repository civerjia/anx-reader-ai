import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anx_reader/service/dictionary/dictionary_library.dart';
import 'package:anx_reader/service/dictionary/stardict.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

/// StarDict order: ASCII case-insensitive, then raw bytes.
int stardictOrder(String a, String b) {
  final x = utf8.encode(a);
  final y = utf8.encode(b);
  int lower(int c) => c >= 65 && c <= 90 ? c + 32 : c;
  for (var i = 0; i < x.length && i < y.length; i++) {
    final d = lower(x[i]) - lower(y[i]);
    if (d != 0) return d;
  }
  if (x.length != y.length) return x.length - y.length;
  for (var i = 0; i < x.length; i++) {
    if (x[i] != y[i]) return x[i] - y[i];
  }
  return 0;
}

class Built {
  Built(this.ifo, this.idx, this.dict);
  final String ifo;
  final Uint8List idx;
  final Uint8List dict;
}

/// A dictionary of [entries] (headword -> raw entry data) in StarDict layout.
Built buildDictionary(
  Map<String, List<int>> entries, {
  String? sameTypeSequence = 'm',
  bool wideOffsets = false,
  String name = 'Test Dictionary',
}) {
  final words = entries.keys.toList()..sort(stardictOrder);
  final dict = BytesBuilder();
  final idx = BytesBuilder();
  for (final word in words) {
    final data = entries[word]!;
    final offset = dict.length;
    dict.add(data);
    idx.add(utf8.encode(word));
    idx.addByte(0);
    final tail = ByteData(wideOffsets ? 12 : 8);
    if (wideOffsets) {
      tail.setUint64(0, offset);
      tail.setUint32(8, data.length);
    } else {
      tail.setUint32(0, offset);
      tail.setUint32(4, data.length);
    }
    idx.add(tail.buffer.asUint8List());
  }
  final idxBytes = idx.toBytes();
  final ifo = StringBuffer()
    ..writeln("StarDict's dict ifo file")
    ..writeln('version=3.0.0')
    ..writeln('bookname=$name')
    ..writeln('wordcount=${words.length}')
    ..writeln('idxfilesize=${idxBytes.length}');
  if (sameTypeSequence != null) ifo.writeln('sametypesequence=$sameTypeSequence');
  if (wideOffsets) ifo.writeln('idxoffsetbits=64');
  return Built(ifo.toString(), idxBytes, dict.toBytes());
}

/// dictzip: gzip with an RA extra field listing separately deflated chunks.
Uint8List dictzip(Uint8List data, int chunkLength) {
  final chunks = <List<int>>[];
  for (var at = 0; at < data.length; at += chunkLength) {
    final end = at + chunkLength < data.length ? at + chunkLength : data.length;
    chunks.add(Deflate(data.sublist(at, end)).getBytes());
  }
  final extra = ByteData(10 + 2 * chunks.length)
    ..setUint8(0, 0x52)
    ..setUint8(1, 0x41)
    ..setUint16(2, 6 + 2 * chunks.length, Endian.little)
    ..setUint16(4, 1, Endian.little)
    ..setUint16(6, chunkLength, Endian.little)
    ..setUint16(8, chunks.length, Endian.little);
  for (var k = 0; k < chunks.length; k++) {
    extra.setUint16(10 + 2 * k, chunks[k].length, Endian.little);
  }
  final out = BytesBuilder()
    ..add([31, 139, 8, 4, 0, 0, 0, 0, 0, 255])
    ..add((ByteData(2)..setUint16(0, extra.lengthInBytes, Endian.little))
        .buffer
        .asUint8List())
    ..add(extra.buffer.asUint8List());
  for (final chunk in chunks) {
    out.add(chunk);
  }
  out.add(List.filled(8, 0));
  return out.toBytes();
}

List<int> text(String s) => utf8.encode(s);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('stardict_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<StarDictionary> install(Built built,
      {bool zipped = false, int chunk = 16, Map<String, List<int>>? syn}) async {
    File('${dir.path}/test.ifo').writeAsStringSync(built.ifo);
    File('${dir.path}/test.idx').writeAsBytesSync(built.idx);
    if (zipped) {
      File('${dir.path}/test.dict.dz').writeAsBytesSync(dictzip(built.dict, chunk));
    } else {
      File('${dir.path}/test.dict').writeAsBytesSync(built.dict);
    }
    if (syn != null) {
      final out = BytesBuilder();
      final words = syn.keys.toList()..sort(stardictOrder);
      for (final word in words) {
        out.add(utf8.encode(word));
        out.addByte(0);
        out.add(syn[word]!);
      }
      File('${dir.path}/test.syn').writeAsBytesSync(out.toBytes());
    }
    return (await StarDictionary.open(File('${dir.path}/test.ifo')))!;
  }

  final sample = {
    'apple': text('a round fruit'),
    'Apple': text('the company'),
    'banana': text('a long yellow fruit'),
    'run': text('to move fast on foot'),
    '苹果': text('apple'),
  };

  group('StarDictionary', () {
    test('finds words ignoring ASCII case, exact case first', () async {
      final dictionary = await install(buildDictionary(sample));
      final apple = await dictionary.lookup('Apple');
      expect(apple.map((e) => e.definition), ['the company', 'a round fruit']);
      expect((await dictionary.lookup('BANANA')).single.definition,
          'a long yellow fruit');
      expect((await dictionary.lookup('苹果')).single.definition, 'apple');
      expect(await dictionary.lookup('cherry'), isEmpty);
      await dictionary.close();
    });

    test('synonyms lead to their headword', () async {
      final built = buildDictionary(sample);
      final words = sample.keys.toList()..sort(stardictOrder);
      final runIndex = ByteData(4)..setUint32(0, words.indexOf('run'));
      final dictionary = await install(built,
          syn: {'ran': runIndex.buffer.asUint8List()});
      final entry = (await dictionary.lookup('ran')).single;
      expect(entry.headword, 'run');
      expect(entry.definition, 'to move fast on foot');
      await dictionary.close();
    });

    test('reads definitions across dictzip chunks', () async {
      final long = {
        for (var i = 0; i < 30; i++)
          'word${i.toString().padLeft(2, '0')}':
              text('definition number $i, long enough to span chunks'),
      };
      final dictionary = await install(buildDictionary(long), zipped: true, chunk: 16);
      for (final i in [0, 13, 29]) {
        final key = 'word${i.toString().padLeft(2, '0')}';
        expect((await dictionary.lookup(key)).single.definition,
            'definition number $i, long enough to span chunks');
      }
      await dictionary.close();
    });

    test('64-bit offsets', () async {
      final dictionary =
          await install(buildDictionary(sample, wideOffsets: true));
      expect((await dictionary.lookup('run')).single.definition,
          'to move fast on foot');
      await dictionary.close();
    });

    test('entries with typed fields and markup', () async {
      final data = [
        ...text('h'),
        ...text('<b>run</b><br>to go &amp; move&#33;'),
        0,
      ];
      final dictionary = await install(
          buildDictionary({'run': data}, sameTypeSequence: null));
      expect((await dictionary.lookup('run')).single.definition,
          'run\nto go & move!');
      await dictionary.close();
    });
  });

  group('definitionText', () {
    test('a phonetic field before the meaning', () {
      final data = Uint8List.fromList([...text('rʌn'), 0, ...text('to move fast')]);
      expect(definitionText(data, 'tm'), '/rʌn/\nto move fast');
    });

    test('binary fields are left out', () {
      final sound = ByteData(4)..setUint32(0, 3);
      final data = Uint8List.fromList([
        ...text('W'), ...sound.buffer.asUint8List(), 1, 2, 3,
        ...text('m'), ...text('meaning'), 0,
      ]);
      expect(definitionText(data, null), 'meaning');
    });
  });

  group('DictionaryLibrary', () {
    test('imports a .tar.bz2 package and looks up inflected words', () async {
      final built = buildDictionary(sample, name: 'Pocket');
      final archive = Archive()
        ..addFile(ArchiveFile('pocket/pocket.ifo', utf8.encode(built.ifo).length,
            utf8.encode(built.ifo)))
        ..addFile(ArchiveFile('pocket/pocket.idx', built.idx.length, built.idx))
        ..addFile(ArchiveFile('pocket/pocket.dict.dz', 0, dictzip(built.dict, 32)))
        ..addFile(ArchiveFile('pocket/README', 5, utf8.encode('hello')));
      final package = File('${dir.path}/pocket.tar.bz2')
        ..writeAsBytesSync(BZip2Encoder().encode(TarEncoder().encode(archive)));

      final library = DictionaryLibrary(Directory('${dir.path}/library'));
      expect(await library.import([package]), ['Pocket']);

      final installed = await library.installed();
      expect(installed.single.name, 'Pocket');
      expect(installed.single.wordCount, sample.length);
      expect(File('${installed.single.folder.path}/pocket.dict.dz').existsSync(), isTrue);
      expect(File('${installed.single.folder.path}/README').existsSync(), isFalse);

      final running = await library.lookup('Running,');
      expect(running.single.headword, 'run');
      expect(running.single.dictionary, 'Pocket');

      await library.remove(installed.single);
      expect(await library.installed(), isEmpty);
      expect(await library.lookup('run'), isEmpty);
    });

    test('loose files selected together', () async {
      final built = buildDictionary(sample, name: 'Loose');
      final ifo = File('${dir.path}/l.ifo')..writeAsStringSync(built.ifo);
      final idx = File('${dir.path}/l.idx')..writeAsBytesSync(built.idx);
      final dict = File('${dir.path}/l.dict')..writeAsBytesSync(built.dict);
      final library = DictionaryLibrary(Directory('${dir.path}/library'));
      expect(await library.import([ifo, idx, dict]), ['Loose']);
      expect((await library.lookup('banana')).single.definition,
          'a long yellow fruit');
    });

    test('a broken dictionary does not hide the others', () async {
      final root = Directory('${dir.path}/library');
      final good = buildDictionary(sample, name: 'Good');
      Directory('${root.path}/good').createSync(recursive: true);
      File('${root.path}/good/g.ifo').writeAsStringSync(good.ifo);
      File('${root.path}/good/g.idx').writeAsBytesSync(good.idx);
      File('${root.path}/good/g.dict').writeAsBytesSync(good.dict);
      // An .ifo whose index and data never arrived.
      Directory('${root.path}/aaa-broken').createSync(recursive: true);
      File('${root.path}/aaa-broken/b.ifo').writeAsStringSync(
          buildDictionary(sample, name: 'Broken').ifo);

      final library = DictionaryLibrary(root);
      expect((await library.lookup('banana')).single.dictionary, 'Good');
    });

    test('nothing installed finds nothing', () async {
      final library = DictionaryLibrary(Directory('${dir.path}/none'));
      expect(await library.installed(), isEmpty);
      expect(await library.lookup('apple'), isEmpty);
    });
  });

  group('helpers', () {
    test('base forms of English words', () {
      expect(englishBaseForms('running'), contains('run'));
      expect(englishBaseForms('stopped'), contains('stop'));
      expect(englishBaseForms('making'), contains('make'));
      expect(englishBaseForms('studies'), contains('study'));
      expect(englishBaseForms('boxes'), contains('box'));
      expect(englishBaseForms("reader's"), contains('reader'));
    });

    test('words and short terms are dictionary terms, passages are not', () {
      expect(isDictionaryTerm('serendipity'), isTrue);
      expect(isDictionaryTerm('look up'), isTrue);
      expect(isDictionaryTerm('苹果'), isTrue);
      expect(isDictionaryTerm('Artemisia arborescens'), isTrue);
      expect(isDictionaryTerm('This is a whole sentence to translate.'), isFalse);
      expect(isDictionaryTerm('在退行的月球继续在塑造地壳方面发挥重要作用。'), isFalse);
      expect(isDictionaryTerm(''), isFalse);
    });

    test('markup to text', () {
      expect(stripMarkup('<p>one</p><p>two&nbsp;three</p>'), 'one\ntwo three');
    });
  });
}
