import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anx_reader/service/dictionary/stardict.dart' show stripMarkup;
import 'package:zstd_dart/zstd_dart.dart';

class ZimFormatException implements Exception {
  const ZimFormatException(this.message);
  final String message;

  @override
  String toString() => 'ZimFormatException: $message';
}

/// One directory entry of a ZIM file: an item stored in a cluster, or a
/// redirect to another entry.
class ZimEntry {
  const ZimEntry({
    required this.index,
    required this.namespace,
    required this.path,
    required this.title,
    required this.mimeType,
    this.redirectIndex,
    this.cluster = 0,
    this.blob = 0,
  });

  final int index;
  final String namespace;
  final String path;

  /// The title, or the path when the entry has none.
  final String title;
  final int mimeType;
  final int? redirectIndex;
  final int cluster;
  final int blob;

  bool get isRedirect => redirectIndex != null;

  @override
  String toString() => 'ZimEntry($index, $namespace/$path)';
}

const _redirectMimeType = 0xffff;
const _linkTargetMimeType = 0xfffe;
const _deletedMimeType = 0xfffd;
const _noTitleIndex = 0xffffffffffffffff;

/// A ZIM archive (Kiwix's offline Wikipedia format) read in place: entries are
/// found by binary search over the file's own sorted lists, and only the
/// clusters an article lives in are read and decompressed.
///
/// Layout as read by libzim: an 80-byte little-endian header; entries sorted by
/// namespace then path; a title-ordered list of entry numbers kept as the
/// blob of `X/listing/titleOrdered/v1` (older files: a table at the header's
/// title index position); clusters whose first byte gives the compression
/// (1 none, 5 zstd; 4 is xz, not supported here) and whether blob offsets are
/// 8 bytes wide.
class ZimArchive {
  ZimArchive._(this._file, this._length, this.entryCount, this.clusterCount,
      this._pathPtrPos, this._clusterPtrPos, this.mimeTypes,
      this._structureStarts);

  final RandomAccessFile _file;
  final int _length;
  final int entryCount;
  final int clusterCount;
  final int _pathPtrPos;
  final int _clusterPtrPos;
  final List<String> mimeTypes;

  /// Where the file's other parts begin, sorted: a cluster ends at the
  /// nearest of these after it, or at the next cluster.
  final List<int> _structureStarts;

  // Title order: either a blob of u32 entry numbers, or the v0 table.
  int _titleListStart = 0;
  int _titleCount = 0;

  Future<void> _pending = Future.value();
  final _clusterCache = <int, _Cluster>{};

  static Future<ZimArchive> open(File source) async {
    final file = await source.open();
    try {
      final length = await file.length();
      final head = await _readAt(file, 0, 80);
      if (head.length < 80) throw const ZimFormatException('file too short');
      final view = ByteData.sublistView(head);
      if (view.getUint32(0, Endian.little) != 0x044d495a) {
        throw const ZimFormatException('not a ZIM file');
      }
      final major = view.getUint16(4, Endian.little);
      if (major != 5 && major != 6) {
        throw ZimFormatException('unsupported ZIM version $major');
      }
      final entryCount = view.getUint32(24, Endian.little);
      final clusterCount = view.getUint32(28, Endian.little);
      final pathPtrPos = view.getUint64(32, Endian.little);
      final titleIdxPos = view.getUint64(40, Endian.little);
      final clusterPtrPos = view.getUint64(48, Endian.little);
      final mimeListPos = view.getUint64(56, Endian.little);
      final checksumPos = view.getUint64(72, Endian.little);

      final mimeBytes = await _readAt(file, mimeListPos, 4096);
      final mimeTypes = <String>[];
      for (var at = 0; at < mimeBytes.length;) {
        final end = mimeBytes.indexOf(0, at);
        if (end <= at) break;
        mimeTypes.add(utf8.decode(mimeBytes.sublist(at, end), allowMalformed: true));
        at = end + 1;
      }

      final structureStarts = <int>{
        mimeListPos,
        pathPtrPos,
        clusterPtrPos,
        if (titleIdxPos != _noTitleIndex) titleIdxPos,
        if (checksumPos > 0 && checksumPos <= length) checksumPos,
        length,
      }.toList()
        ..sort();
      final archive = ZimArchive._(file, length, entryCount, clusterCount,
          pathPtrPos, clusterPtrPos, mimeTypes, structureStarts);
      final listing = await archive.findByPath('X', 'listing/titleOrdered/v1');
      if (listing != null && !listing.isRedirect) {
        final place = await archive._blobPlace(listing.cluster, listing.blob);
        if (place != null) {
          archive._titleListStart = place.$1;
          archive._titleCount = place.$2 ~/ 4;
        }
      }
      if (archive._titleCount == 0 && titleIdxPos != _noTitleIndex && titleIdxPos != 0) {
        archive._titleListStart = titleIdxPos;
        archive._titleCount = entryCount;
      }
      return archive;
    } catch (_) {
      await file.close();
      rethrow;
    }
  }

  static Future<Uint8List> _readAt(RandomAccessFile file, int offset, int size) async {
    await file.setPosition(offset);
    return file.read(size);
  }

  /// Reads run one after another: the file position is shared.
  Future<Uint8List> _read(int offset, int size) {
    final done = Completer<Uint8List>();
    _pending = _pending.then((_) async {
      try {
        done.complete(await _readAt(_file, offset, size));
      } catch (e, stack) {
        done.completeError(e, stack);
      }
    });
    return done.future;
  }

  Future<int> _u64At(int offset) async =>
      ByteData.sublistView(await _read(offset, 8)).getUint64(0, Endian.little);

  Future<int> _u32At(int offset) async =>
      ByteData.sublistView(await _read(offset, 4)).getUint32(0, Endian.little);

  Future<ZimEntry> entryAt(int index) async {
    if (index < 0 || index >= entryCount) {
      throw ZimFormatException('entry $index out of range');
    }
    final offset = await _u64At(_pathPtrPos + 8 * index);
    var window = 512;
    while (true) {
      final bytes = await _read(offset, window);
      final entry = _parseEntry(index, bytes);
      if (entry != null) return entry;
      if (bytes.length < window || window >= 65536) {
        throw ZimFormatException('entry $index is truncated');
      }
      window *= 4;
    }
  }

  static ZimEntry? _parseEntry(int index, Uint8List bytes) {
    if (bytes.length < 12) return null;
    final view = ByteData.sublistView(bytes);
    final mime = view.getUint16(0, Endian.little);
    final namespace = String.fromCharCode(bytes[3]);
    final redirect = mime == _redirectMimeType;
    final pathStart = redirect ? 12 : 16;
    if (bytes.length < pathStart + 2) return null;
    final pathEnd = bytes.indexOf(0, pathStart);
    if (pathEnd < 0) return null;
    final titleEnd = bytes.indexOf(0, pathEnd + 1);
    if (titleEnd < 0) return null;
    final path = utf8.decode(bytes.sublist(pathStart, pathEnd), allowMalformed: true);
    final title = titleEnd == pathEnd + 1
        ? path
        : utf8.decode(bytes.sublist(pathEnd + 1, titleEnd), allowMalformed: true);
    if (redirect) {
      return ZimEntry(
        index: index,
        namespace: namespace,
        path: path,
        title: title,
        mimeType: mime,
        redirectIndex: view.getUint32(8, Endian.little),
      );
    }
    return ZimEntry(
      index: index,
      namespace: namespace,
      path: path,
      title: title,
      mimeType: mime,
      cluster: view.getUint32(8, Endian.little),
      blob: view.getUint32(12, Endian.little),
    );
  }

  static int _compareBytes(List<int> a, List<int> b) {
    final shared = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < shared; i++) {
      final d = a[i] - b[i];
      if (d != 0) return d;
    }
    return a.length - b.length;
  }

  static List<int> _key(String namespace, String text) =>
      [namespace.codeUnitAt(0), ...utf8.encode(text)];

  Future<ZimEntry?> findByPath(String namespace, String path) async {
    final key = _key(namespace, path);
    var low = 0;
    var high = entryCount;
    while (low < high) {
      final mid = (low + high) >> 1;
      final entry = await entryAt(mid);
      if (_compareBytes(_key(entry.namespace, entry.path), key) < 0) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    if (low >= entryCount) return null;
    final entry = await entryAt(low);
    return entry.namespace == namespace && entry.path == path ? entry : null;
  }

  bool get hasTitleIndex => _titleCount > 0;

  Future<ZimEntry> _titleAt(int position) async =>
      entryAt(await _u32At(_titleListStart + 4 * position));

  Future<int> _titleLowerBound(List<int> key) async {
    var low = 0;
    var high = _titleCount;
    while (low < high) {
      final mid = (low + high) >> 1;
      final entry = await _titleAt(mid);
      if (_compareBytes(_key(entry.namespace, entry.title), key) < 0) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  /// The entry titled exactly [title], if any (not resolved through redirects).
  Future<ZimEntry?> findByTitle(String title, {String namespace = 'C'}) async {
    if (!hasTitleIndex) return null;
    final at = await _titleLowerBound(_key(namespace, title));
    if (at >= _titleCount) return null;
    final entry = await _titleAt(at);
    return entry.namespace == namespace && entry.title == title ? entry : null;
  }

  /// Up to [limit] titles beginning with [prefix], in title order.
  Future<List<ZimEntry>> titlesStartingWith(String prefix,
      {String namespace = 'C', int limit = 10}) async {
    if (!hasTitleIndex || prefix.isEmpty) return const [];
    final key = _key(namespace, prefix);
    final found = <ZimEntry>[];
    for (var at = await _titleLowerBound(key);
        at < _titleCount && found.length < limit;
        at++) {
      final entry = await _titleAt(at);
      final entryKey = _key(entry.namespace, entry.title);
      if (entryKey.length < key.length ||
          _compareBytes(entryKey.sublist(0, key.length), key) != 0) {
        break;
      }
      found.add(entry);
    }
    return found;
  }

  /// Follows redirects to the entry holding the content.
  Future<ZimEntry> resolve(ZimEntry entry) async {
    var current = entry;
    for (var hops = 0; current.isRedirect; hops++) {
      if (hops > 16) throw const ZimFormatException('redirect loop');
      current = await entryAt(current.redirectIndex!);
    }
    return current;
  }

  String mimeTypeOf(ZimEntry entry) =>
      entry.mimeType < mimeTypes.length ? mimeTypes[entry.mimeType] : '';

  Future<Uint8List> content(ZimEntry entry) async {
    final item = await resolve(entry);
    if (item.mimeType == _linkTargetMimeType || item.mimeType == _deletedMimeType) {
      return Uint8List(0);
    }
    return _blob(item.cluster, item.blob);
  }

  Future<Map<String, String>> metadata() async {
    final result = <String, String>{};
    for (final name in const [
      'Title', 'Name', 'Language', 'Description', 'Date', 'Flavour', 'Creator',
      'Publisher', 'Counter',
    ]) {
      final entry = await findByPath('M', name);
      if (entry == null || entry.isRedirect) continue;
      result[name] = utf8.decode(await _blob(entry.cluster, entry.blob),
          allowMalformed: true);
    }
    return result;
  }

  Future<(int start, int end)> _clusterRange(int cluster) async {
    if (cluster < 0 || cluster >= clusterCount) {
      throw ZimFormatException('cluster $cluster out of range');
    }
    final start = await _u64At(_clusterPtrPos + 8 * cluster);
    // zstd needs a compressed cluster to the exact byte. In Kiwix files the
    // cluster pointer list follows the last cluster, so the checksum is not
    // where that cluster ends.
    var end = _length;
    for (final at in _structureStarts) {
      if (at > start) {
        end = at;
        break;
      }
    }
    if (cluster + 1 < clusterCount) {
      final next = await _u64At(_clusterPtrPos + 8 * (cluster + 1));
      if (next > start && next < end) end = next;
    }
    return (start, end);
  }

  /// Where an uncompressed blob sits in the file (start, size); null when its
  /// cluster is compressed.
  Future<(int, int)?> _blobPlace(int cluster, int blob) async {
    final (start, _) = await _clusterRange(cluster);
    final info = (await _read(start, 1))[0];
    if ((info & 0x0f) > 1) return null;
    final wide = (info & 0x10) != 0;
    final width = wide ? 8 : 4;
    final pair = ByteData.sublistView(await _read(start + 1 + width * blob, 2 * width));
    final from = wide ? pair.getUint64(0, Endian.little) : pair.getUint32(0, Endian.little);
    final to = wide ? pair.getUint64(8, Endian.little) : pair.getUint32(4, Endian.little);
    return (start + 1 + from, to - from);
  }

  Future<Uint8List> _blob(int cluster, int blob) async {
    final place = await _blobPlace(cluster, blob);
    if (place != null) return _read(place.$1, place.$2);
    final data = await _decompressedCluster(cluster);
    return data.blob(blob);
  }

  Future<_Cluster> _decompressedCluster(int index) async {
    final cached = _clusterCache.remove(index);
    if (cached != null) {
      _clusterCache[index] = cached;
      return cached;
    }
    final (start, end) = await _clusterRange(index);
    final raw = await _read(start, end - start);
    final info = raw[0];
    final compression = info & 0x0f;
    final Uint8List data;
    switch (compression) {
      case 5:
        data = ZstdCodec.decompress(Uint8List.sublistView(raw, 1));
      case 4:
        throw const ZimFormatException('xz-compressed ZIM files are not supported');
      default:
        data = Uint8List.sublistView(raw, 1);
    }
    final cluster = _Cluster(data, (info & 0x10) != 0);
    _clusterCache[index] = cluster;
    while (_clusterCache.length > 4) {
      _clusterCache.remove(_clusterCache.keys.first);
    }
    return cluster;
  }

  Future<void> close() async {
    await _pending;
    await _file.close();
  }
}

class _Cluster {
  _Cluster(this.data, this.wide);

  final Uint8List data;
  final bool wide;

  Uint8List blob(int index) {
    final view = ByteData.sublistView(data);
    final width = wide ? 8 : 4;
    int offsetAt(int k) => wide
        ? view.getUint64(k * width, Endian.little)
        : view.getUint32(k * width, Endian.little);
    final count = offsetAt(0) ~/ width - 1;
    if (index < 0 || index >= count) {
      throw ZimFormatException('blob $index out of range');
    }
    return Uint8List.sublistView(data, offsetAt(index), offsetAt(index + 1));
  }
}

/// The opening paragraphs of a Wikipedia article page as plain text — what a
/// reader or a model needs from it — without infoboxes, tables or scripts.
final _coordinates = RegExp(
    r'-?\d+(?:\.\d+)?°(?:\s*\d+(?:\.\d+)?′)?(?:\s*\d+(?:\.\d+)?″)?\s*[NSEW]?'
    r'|-?\d+\.\d+\s*;\s*-?\d+\.\d+');

String articleLeadText(String html, {int maxCharacters = 1200}) {
  var cleaned = html
      .replaceAll(RegExp(r'<(script|style)[^>]*>[\s\S]*?</\1>', caseSensitive: false), '')
      .replaceAll(RegExp(r'<sup[^>]*>[\s\S]*?</sup>', caseSensitive: false), '');
  // Infoboxes and other tables hold paragraphs too (缅甸's map caption);
  // remove innermost tables until none are left.
  final innermostTable = RegExp(r'<table\b(?:(?!<table\b)[\s\S])*?</table>', caseSensitive: false);
  while (innermostTable.hasMatch(cleaned)) {
    cleaned = cleaned.replaceAll(innermostTable, '');
  }
  final paragraphs = <String>[];
  var length = 0;
  for (final match in RegExp(r'<p[^>]*>([\s\S]*?)</p>', caseSensitive: false)
      .allMatches(cleaned)) {
    final text = stripMarkup(match[1]!).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.length < 6) continue;
    // A paragraph that is a coordinate line (黄河源 34°29′31″N 96°20′25″E …).
    final withoutCoordinates = text.replaceAll(_coordinates, '');
    if (RegExp(r'\d°').hasMatch(text) &&
        RegExp(r'[一-鿿]').allMatches(withoutCoordinates).length < 6 &&
        withoutCoordinates.replaceAll(RegExp(r'[\s/;\ufeff]'), '').length < 12) {
      continue;
    }
    paragraphs.add(text);
    length += text.length;
    if (length >= maxCharacters) break;
  }
  var result = paragraphs.join('\n');
  if (result.isEmpty) {
    result = stripMarkup(cleaned).replaceAll(RegExp(r'\s+'), ' ').trim();
  }
  return result.length > maxCharacters ? '${result.substring(0, maxCharacters)}…' : result;
}
