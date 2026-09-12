import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// The fields of a StarDict `.ifo` file that matter for reading it.
class StarDictInfo {
  const StarDictInfo({
    required this.name,
    required this.wordCount,
    this.sameTypeSequence,
    this.idxOffsetBits = 32,
  });

  final String name;
  final int wordCount;

  /// When set, every entry holds these field types in this order, without the
  /// per-field type marks.
  final String? sameTypeSequence;
  final int idxOffsetBits;

  static StarDictInfo? parse(String text) {
    final lines = const LineSplitter().convert(text.replaceFirst('﻿', ''));
    if (lines.isEmpty ||
        !lines.first.trim().startsWith("StarDict's dict ifo file")) {
      return null;
    }
    final fields = <String, String>{};
    for (final line in lines.skip(1)) {
      final separator = line.indexOf('=');
      if (separator > 0) {
        fields[line.substring(0, separator).trim()] =
            line.substring(separator + 1).trim();
      }
    }
    final sequence = fields['sametypesequence'];
    return StarDictInfo(
      name: fields['bookname'] ?? '',
      wordCount: int.tryParse(fields['wordcount'] ?? '') ?? 0,
      sameTypeSequence: sequence == null || sequence.isEmpty ? null : sequence,
      idxOffsetBits: int.tryParse(fields['idxoffsetbits'] ?? '') ?? 32,
    );
  }
}

class DictionaryEntry {
  const DictionaryEntry({
    required this.dictionary,
    required this.headword,
    required this.definition,
  });

  final String dictionary;
  final String headword;
  final String definition;

  @override
  String toString() => 'DictionaryEntry($dictionary, $headword)';
}

int _asciiLower(int byte) => byte >= 0x41 && byte <= 0x5A ? byte + 32 : byte;

/// The words of an `.idx` or `.syn` file, in file order, which StarDict keeps
/// sorted by ASCII letters case-insensitively, ties broken by the raw bytes.
class _WordList {
  _WordList._(this.bytes, this.starts, this.ends, this._view);

  final Uint8List bytes;
  final Int32List starts;
  final Int32List ends;
  final ByteData _view;

  /// [tail] is the number of bytes after each word's terminating zero.
  factory _WordList.parse(Uint8List bytes, int tail) {
    final starts = <int>[];
    final ends = <int>[];
    var i = 0;
    while (i < bytes.length) {
      final end = bytes.indexOf(0, i);
      // A word without its terminating zero or its full tail is a truncated file.
      if (end < 0 || end + 1 + tail > bytes.length) {
        break;
      }
      starts.add(i);
      ends.add(end);
      i = end + 1 + tail;
    }
    return _WordList._(bytes, Int32List.fromList(starts), Int32List.fromList(ends),
        ByteData.sublistView(bytes));
  }

  int get length => starts.length;

  String word(int i) =>
      utf8.decode(Uint8List.sublistView(bytes, starts[i], ends[i]),
          allowMalformed: true);

  int _caseless(int i, Uint8List query) {
    final start = starts[i];
    final length = ends[i] - start;
    final shared = length < query.length ? length : query.length;
    for (var k = 0; k < shared; k++) {
      final difference = _asciiLower(bytes[start + k]) - _asciiLower(query[k]);
      if (difference != 0) return difference;
    }
    return length - query.length;
  }

  bool _exact(int i, Uint8List query) {
    final start = starts[i];
    if (ends[i] - start != query.length) return false;
    for (var k = 0; k < query.length; k++) {
      if (bytes[start + k] != query[k]) return false;
    }
    return true;
  }

  /// Every word equal to [query] ignoring ASCII case, exact matches first.
  List<int> find(Uint8List query) {
    var low = 0;
    var high = length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (_caseless(mid, query) < 0) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    final found = <int>[];
    for (var i = low; i < length && _caseless(i, query) == 0; i++) {
      found.add(i);
    }
    found.sort((a, b) => (_exact(b, query) ? 1 : 0) - (_exact(a, query) ? 1 : 0));
    return found;
  }

  int uint32(int i, int at) => _view.getUint32(ends[i] + 1 + at);
  int uint64(int i, int at) => _view.getUint64(ends[i] + 1 + at);
}

abstract class _DictData {
  Future<Uint8List> read(int offset, int size);
  Future<void> close();
}

class _MemoryDictData implements _DictData {
  _MemoryDictData(this.bytes);
  final Uint8List bytes;

  @override
  Future<Uint8List> read(int offset, int size) async =>
      Uint8List.sublistView(bytes, offset, offset + size);

  @override
  Future<void> close() async {}
}

class _FileDictData implements _DictData {
  _FileDictData(this.file);
  final RandomAccessFile file;

  @override
  Future<Uint8List> read(int offset, int size) async {
    await file.setPosition(offset);
    return file.read(size);
  }

  @override
  Future<void> close() => file.close();
}

/// A dictzip file: gzip whose extra field lists independently deflated chunks,
/// so a definition can be read without inflating the whole dictionary.
class _DictZipData implements _DictData {
  _DictZipData._(this.file, this.chunkLength, this.chunkOffsets);

  final RandomAccessFile file;
  final int chunkLength;

  /// Start of each compressed chunk in the file, plus the end of the last.
  final List<int> chunkOffsets;
  final _cache = <int, Uint8List>{};

  static Future<_DictData> open(File source) async {
    final file = await source.open();
    final head = await file.read(12);
    final view = ByteData.sublistView(head);
    final flags = head.length == 12 ? head[3] : 0;
    if (head.length < 12 || head[0] != 31 || head[1] != 139 || (flags & 4) == 0) {
      await file.close();
      return _MemoryDictData(Uint8List.fromList(
          GZipDecoder().decodeBytes(await source.readAsBytes())));
    }
    final extraLength = view.getUint16(10, Endian.little);
    final extra = await file.read(extraLength);
    final extraView = ByteData.sublistView(extra);
    int? chunkLength;
    List<int>? sizes;
    for (var at = 0; at + 4 <= extra.length;) {
      final length = extraView.getUint16(at + 2, Endian.little);
      if (extra[at] == 0x52 && extra[at + 1] == 0x41 && at + 10 <= extra.length) {
        chunkLength = extraView.getUint16(at + 6, Endian.little);
        final count = extraView.getUint16(at + 8, Endian.little);
        sizes = [
          for (var k = 0; k < count; k++)
            extraView.getUint16(at + 10 + 2 * k, Endian.little),
        ];
      }
      at += 4 + length;
    }
    if (chunkLength == null || sizes == null) {
      await file.close();
      return _MemoryDictData(Uint8List.fromList(
          GZipDecoder().decodeBytes(await source.readAsBytes())));
    }
    var position = 12 + extraLength;
    Future<void> skipZeroTerminated() async {
      await file.setPosition(position);
      while (true) {
        final byte = await file.readByte();
        position++;
        if (byte <= 0) break;
      }
    }

    if ((flags & 8) != 0) await skipZeroTerminated();
    if ((flags & 16) != 0) await skipZeroTerminated();
    if ((flags & 2) != 0) position += 2;
    final offsets = <int>[position];
    for (final size in sizes) {
      offsets.add(offsets.last + size);
    }
    return _DictZipData._(file, chunkLength, offsets);
  }

  Future<Uint8List> _chunk(int index) async {
    final cached = _cache[index];
    if (cached != null) return cached;
    await file.setPosition(chunkOffsets[index]);
    final compressed =
        await file.read(chunkOffsets[index + 1] - chunkOffsets[index]);
    final inflated = Uint8List.fromList(Inflate(compressed).getBytes());
    if (_cache.length > 16) _cache.remove(_cache.keys.first);
    _cache[index] = inflated;
    return inflated;
  }

  @override
  Future<Uint8List> read(int offset, int size) async {
    final out = BytesBuilder(copy: false);
    var remaining = size;
    var position = offset;
    while (remaining > 0) {
      final index = position ~/ chunkLength;
      if (index >= chunkOffsets.length - 1) break;
      final chunk = await _chunk(index);
      final start = position - index * chunkLength;
      if (start >= chunk.length) break;
      final take = remaining < chunk.length - start ? remaining : chunk.length - start;
      out.add(Uint8List.sublistView(chunk, start, start + take));
      remaining -= take;
      position += take;
    }
    return out.takeBytes();
  }

  @override
  Future<void> close() => file.close();
}

/// Turns one entry's data into readable text, whatever mix of field types the
/// dictionary uses.
String definitionText(Uint8List data, String? sameTypeSequence) {
  final parts = <String>[];
  var at = 0;

  String readField(String type, bool last) {
    final lower = type.toLowerCase() == type;
    Uint8List bytes;
    if (lower) {
      if (last && sameTypeSequence != null) {
        bytes = Uint8List.sublistView(data, at);
        at = data.length;
      } else {
        final end = data.indexOf(0, at);
        final stop = end < 0 ? data.length : end;
        bytes = Uint8List.sublistView(data, at, stop);
        at = stop + 1;
      }
    } else {
      if (last && sameTypeSequence != null) {
        bytes = Uint8List.sublistView(data, at);
        at = data.length;
      } else {
        if (at + 4 > data.length) {
          at = data.length;
          return '';
        }
        final size = ByteData.sublistView(data).getUint32(at);
        final end = (at + 4 + size).clamp(0, data.length);
        bytes = Uint8List.sublistView(data, at + 4, end);
        at = end;
      }
      // Binary fields (sounds, pictures) have nothing to show as text.
      return '';
    }
    final text = utf8.decode(bytes, allowMalformed: true);
    switch (type) {
      case 't':
        return text.trim().isEmpty ? '' : '/${text.trim()}/';
      case 'h':
      case 'g':
      case 'x':
      case 'k':
      case 'w':
        return stripMarkup(text);
      case 'r':
        return '';
      default:
        return text.trim();
    }
  }

  if (sameTypeSequence != null) {
    for (var k = 0; k < sameTypeSequence.length && at < data.length; k++) {
      final text =
          readField(sameTypeSequence[k], k == sameTypeSequence.length - 1);
      if (text.isNotEmpty) parts.add(text);
    }
  } else {
    while (at < data.length) {
      final type = String.fromCharCode(data[at]);
      at++;
      final text = readField(type, false);
      if (text.isNotEmpty) parts.add(text);
    }
  }
  return parts.join('\n');
}

final _entity = RegExp(r'&(#x[0-9a-fA-F]+|#\d+|[a-zA-Z]+);');
const _namedEntities = {
  'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'", 'nbsp': ' ',
};

/// HTML, Pango and XDXF markup reduced to text with its line breaks.
String stripMarkup(String markup) {
  var text = markup
      .replaceAll(RegExp(r'<\s*br\s*/?\s*>', caseSensitive: false), '\n')
      .replaceAll(
          RegExp(r'</\s*(p|div|li|tr|h\d|blockquote|def|ex)\s*>',
              caseSensitive: false),
          '\n')
      .replaceAll(RegExp(r'<[^>]*>'), '');
  text = text.replaceAllMapped(_entity, (match) {
    final name = match[1]!;
    if (name.startsWith('#x')) {
      return String.fromCharCode(int.tryParse(name.substring(2), radix: 16) ?? 63);
    }
    if (name.startsWith('#')) {
      return String.fromCharCode(int.tryParse(name.substring(1)) ?? 63);
    }
    return _namedEntities[name.toLowerCase()] ?? match[0]!;
  });
  return text
      .split('\n')
      .map((line) => line.trimRight())
      .join('\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

/// An installed StarDict dictionary: the `.ifo`, `.idx` (or `.idx.gz`),
/// `.dict` (or `.dict.dz`) and optional `.syn` files of one base name.
class StarDictionary {
  StarDictionary._(this.info, this._index, this._synonyms, this._data);

  final StarDictInfo info;
  final _WordList _index;
  final _WordList? _synonyms;
  final _DictData _data;

  String get name => info.name;

  static Future<StarDictionary?> open(File ifo) async {
    final info = StarDictInfo.parse(await ifo.readAsString());
    if (info == null) return null;
    final base = ifo.path.substring(0, ifo.path.length - '.ifo'.length);

    Uint8List? idxBytes;
    if (File('$base.idx').existsSync()) {
      idxBytes = await File('$base.idx').readAsBytes();
    } else if (File('$base.idx.gz').existsSync()) {
      idxBytes = Uint8List.fromList(
          GZipDecoder().decodeBytes(await File('$base.idx.gz').readAsBytes()));
    }
    if (idxBytes == null) return null;

    _DictData? data;
    if (File('$base.dict').existsSync()) {
      data = _FileDictData(await File('$base.dict').open());
    } else if (File('$base.dict.dz').existsSync()) {
      data = await _DictZipData.open(File('$base.dict.dz'));
    }
    if (data == null) return null;

    final offsetBytes = info.idxOffsetBits == 64 ? 8 : 4;
    final synonyms = File('$base.syn').existsSync()
        ? _WordList.parse(await File('$base.syn').readAsBytes(), 4)
        : null;
    return StarDictionary._(
      info,
      _WordList.parse(idxBytes, offsetBytes + 4),
      synonyms,
      data,
    );
  }

  Future<List<DictionaryEntry>> lookup(String word, {int limit = 6}) async {
    final query = Uint8List.fromList(utf8.encode(word.trim()));
    if (query.isEmpty) return const [];
    final found = <int>[..._index.find(query)];
    final synonyms = _synonyms;
    if (synonyms != null) {
      for (final i in synonyms.find(query)) {
        final target = synonyms.uint32(i, 0);
        if (target < _index.length && !found.contains(target)) found.add(target);
      }
    }
    final wide = info.idxOffsetBits == 64;
    final entries = <DictionaryEntry>[];
    for (final i in found.take(limit)) {
      final offset = wide ? _index.uint64(i, 0) : _index.uint32(i, 0);
      final size = _index.uint32(i, wide ? 8 : 4);
      final data = await _data.read(offset, size);
      final definition = definitionText(data, info.sameTypeSequence);
      if (definition.isEmpty) continue;
      entries.add(DictionaryEntry(
        dictionary: info.name,
        headword: _index.word(i),
        definition: definition,
      ));
    }
    return entries;
  }

  Future<void> close() => _data.close();
}

/// Base forms an English word may have been inflected from, most likely first.
List<String> englishBaseForms(String word) {
  final w = word.toLowerCase();
  final forms = <String>[];
  void add(String form) {
    if (form.length >= 2 && form != w && !forms.contains(form)) forms.add(form);
  }

  if (w.endsWith("'s")) add(w.substring(0, w.length - 2));
  if (w.endsWith('ies')) add('${w.substring(0, w.length - 3)}y');
  if (w.endsWith('ied')) add('${w.substring(0, w.length - 3)}y');
  if (w.endsWith('es')) add(w.substring(0, w.length - 2));
  if (w.endsWith('s') && !w.endsWith('ss')) add(w.substring(0, w.length - 1));
  for (final suffix in ['ing', 'ed', 'er', 'est']) {
    if (w.endsWith(suffix) && w.length > suffix.length + 2) {
      final stem = w.substring(0, w.length - suffix.length);
      // Doubled consonant: running -> run, stopped -> stop.
      if (stem.length >= 3 && stem[stem.length - 1] == stem[stem.length - 2]) {
        add(stem.substring(0, stem.length - 1));
      }
      add(stem);
      add('${stem}e'); // making -> make
    }
  }
  if (w.endsWith('ly') && w.length > 4) add(w.substring(0, w.length - 2));
  return forms;
}

/// Whether a selection reads as a word or short term worth looking up rather
/// than a passage to translate.
bool isDictionaryTerm(String text) {
  final t = text.trim();
  if (t.isEmpty || t.contains('\n') || t.length > 40) return false;
  final hasCjk = RegExp(r'[぀-ヿ㐀-鿿豈-﫿]').hasMatch(t);
  if (hasCjk) return t.runes.length <= 8 && !RegExp(r'[，。！？；：、]').hasMatch(t);
  return t.split(RegExp(r'\s+')).length <= 3;
}
