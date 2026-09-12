import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// StarDict's headword order: ASCII letters without case, ties by raw bytes.
int stardictCompare(String a, String b) {
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

class StarDictSource {
  StarDictSource({
    required this.name,
    required this.description,
    required this.author,
    required this.website,
    required this.sameTypeSequence,
  });

  final String name;
  final String description;
  final String author;
  final String website;
  final String sameTypeSequence;

  /// Headword -> entry data (already laid out for [sameTypeSequence]).
  final entries = <String, List<int>>{};

  /// Alternative form -> headword it leads to.
  final synonyms = <String, String>{};
}

/// Writes [source] as `<base>.ifo`, `.idx`, `.dict.dz` and (if any) `.syn`.
/// Returns the file sizes.
Map<String, int> writeStarDict(StarDictSource source, String base,
    {int chunkLength = 32768}) {
  final words = source.entries.keys.toList()..sort(stardictCompare);
  final indexOf = {for (var i = 0; i < words.length; i++) words[i]: i};

  final dict = BytesBuilder(copy: false);
  final idx = BytesBuilder(copy: false);
  for (final word in words) {
    final data = source.entries[word]!;
    final tail = ByteData(8)
      ..setUint32(0, dict.length)
      ..setUint32(4, data.length);
    dict.add(data);
    idx
      ..add(utf8.encode(word))
      ..addByte(0)
      ..add(tail.buffer.asUint8List());
  }

  final synonyms = source.synonyms.entries
      .where((e) => indexOf.containsKey(e.value) && !indexOf.containsKey(e.key))
      .toList()
    ..sort((a, b) => stardictCompare(a.key, b.key));
  final syn = BytesBuilder(copy: false);
  for (final e in synonyms) {
    syn
      ..add(utf8.encode(e.key))
      ..addByte(0)
      ..add((ByteData(4)..setUint32(0, indexOf[e.value]!)).buffer.asUint8List());
  }

  final idxBytes = idx.toBytes();
  final ifo = StringBuffer()
    ..writeln("StarDict's dict ifo file")
    ..writeln('version=3.0.0')
    ..writeln('bookname=${source.name}')
    ..writeln('wordcount=${words.length}')
    ..writeln('idxfilesize=${idxBytes.length}')
    ..writeln('sametypesequence=${source.sameTypeSequence}')
    ..writeln('author=${source.author}')
    ..writeln('website=${source.website}')
    ..writeln('description=${source.description.replaceAll('\n', '<br>')}');
  if (synonyms.isNotEmpty) ifo.writeln('synwordcount=${synonyms.length}');

  File('$base.ifo').writeAsStringSync(ifo.toString());
  File('$base.idx').writeAsBytesSync(idxBytes);
  File('$base.dict.dz').writeAsBytesSync(_dictzip(dict.toBytes(), chunkLength));
  if (synonyms.isNotEmpty) File('$base.syn').writeAsBytesSync(syn.toBytes());
  return {
    for (final ext in ['ifo', 'idx', 'dict.dz', 'syn'])
      if (File('$base.$ext').existsSync()) ext: File('$base.$ext').lengthSync(),
  };
}

/// dictzip: a gzip file whose RA extra field lists separately deflated chunks.
Uint8List _dictzip(Uint8List data, int chunkLength) {
  final chunks = <List<int>>[];
  for (var at = 0; at < data.length; at += chunkLength) {
    final end = at + chunkLength < data.length ? at + chunkLength : data.length;
    chunks.add(Deflate(data.sublist(at, end), level: 9).getBytes());
  }
  if (chunks.length > 65535 - 10) throw StateError('too many dictzip chunks');
  final extraLength = 10 + 2 * chunks.length;
  final extra = ByteData(extraLength)
    ..setUint8(0, 0x52)
    ..setUint8(1, 0x41)
    ..setUint16(2, 6 + 2 * chunks.length, Endian.little)
    ..setUint16(4, 1, Endian.little)
    ..setUint16(6, chunkLength, Endian.little)
    ..setUint16(8, chunks.length, Endian.little);
  for (var k = 0; k < chunks.length; k++) {
    if (chunks[k].length > 65535) throw StateError('chunk too large');
    extra.setUint16(10 + 2 * k, chunks[k].length, Endian.little);
  }
  final crc = getCrc32(data);
  final trailer = ByteData(8)
    ..setUint32(0, crc, Endian.little)
    ..setUint32(4, data.length & 0xffffffff, Endian.little);
  final out = BytesBuilder(copy: false)
    ..add([31, 139, 8, 4, 0, 0, 0, 0, 2, 255])
    ..add((ByteData(2)..setUint16(0, extraLength, Endian.little)).buffer.asUint8List())
    ..add(extra.buffer.asUint8List());
  for (final chunk in chunks) {
    out.add(chunk);
  }
  out.add(trailer.buffer.asUint8List());
  return out.toBytes();
}

/// Reads a CSV file (RFC 4180: quoted fields may contain commas, quotes and
/// line breaks) as rows of fields.
Stream<List<String>> readCsv(File file) async* {
  final lines = file.openRead().transform(utf8.decoder).transform(const LineSplitter());
  var fields = <String>[];
  final field = StringBuffer();
  var quoted = false;
  await for (final line in lines) {
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (quoted) {
        if (c == '"') {
          if (i + 1 < line.length && line[i + 1] == '"') {
            field.write('"');
            i++;
          } else {
            quoted = false;
          }
        } else {
          field.write(c);
        }
      } else if (c == '"') {
        quoted = true;
      } else if (c == ',') {
        fields.add(field.toString());
        field.clear();
      } else {
        field.write(c);
      }
    }
    if (quoted) {
      field.write('\n');
      continue;
    }
    fields.add(field.toString());
    field.clear();
    yield fields;
    fields = <String>[];
  }
}
