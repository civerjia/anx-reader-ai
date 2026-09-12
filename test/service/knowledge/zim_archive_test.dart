import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anx_reader/service/knowledge/zim_archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zstd_dart/zstd_dart.dart';

class _Item {
  _Item(this.namespace, this.path, {this.mime = 0, this.content, this.redirectTo});
  final String namespace;
  final String path;
  final int mime;
  final List<int>? content;
  final String? redirectTo;
  int cluster = 0;
  int blob = 0;
  List<int> get key => [namespace.codeUnitAt(0), ...utf8.encode(path)];
}

int _cmp(List<int> a, List<int> b) {
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (a[i] != b[i]) return a[i] - b[i];
  }
  return a.length - b.length;
}

List<int> _u16(int v) => (ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List();
List<int> _u32(int v) => (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();
List<int> _u64(int v) => (ByteData(8)..setUint64(0, v, Endian.little)).buffer.asUint8List();

/// Writes a small ZIM laid out as Kiwix files are: metadata and the v1 title
/// listing in an uncompressed cluster, article pages in a zstd cluster, no v0
/// title table.
Uint8List buildZim(Map<String, String> articles, Map<String, String> redirects,
    Map<String, String> metadata) {
  final mimes = ['text/html', 'text/plain', 'application/octet-stream+zimlisting'];
  final items = <_Item>[
    for (final e in articles.entries)
      _Item('C', e.key, content: utf8.encode(e.value)),
    for (final e in redirects.entries) _Item('C', e.key, redirectTo: e.value),
    for (final e in metadata.entries)
      _Item('M', e.key, mime: 1, content: utf8.encode(e.value)),
  ];
  final listing = _Item('X', 'listing/titleOrdered/v1', mime: 2);
  items
    ..add(listing)
    ..sort((a, b) => _cmp(a.key, b.key));
  final indexOf = {
    for (var i = 0; i < items.length; i++) '${items[i].namespace}/${items[i].path}': i,
  };
  // Titles are empty, so title order is path order within C.
  final titleOrder = [
    for (var i = 0; i < items.length; i++)
      if (items[i].namespace == 'C') i,
  ];

  final plain = <List<int>>[];
  final zstd = <List<int>>[];
  for (final item in items) {
    if (item.redirectTo != null) continue;
    if (item.namespace == 'C') {
      item
        ..cluster = 1
        ..blob = zstd.length;
      zstd.add(item.content!);
    } else {
      item
        ..cluster = 0
        ..blob = plain.length;
      plain.add(item == listing ? [for (final i in titleOrder) ..._u32(i)] : item.content!);
    }
  }

  List<int> clusterBody(List<List<int>> blobs) {
    final offsets = <int>[];
    var at = 4 * (blobs.length + 1);
    for (final b in blobs) {
      offsets.add(at);
      at += b.length;
    }
    offsets.add(at);
    return [for (final o in offsets) ..._u32(o), for (final b in blobs) ...b];
  }

  final out = BytesBuilder()..add(Uint8List(80));
  final mimeListPos = out.length;
  for (final m in mimes) {
    out
      ..add(utf8.encode(m))
      ..addByte(0);
  }
  out.addByte(0);

  final direntOffsets = <int>[];
  for (final item in items) {
    direntOffsets.add(out.length);
    final ns = item.namespace.codeUnitAt(0);
    if (item.redirectTo != null) {
      out.add([..._u16(0xffff), 0, ns, ..._u32(0), ..._u32(indexOf['C/${item.redirectTo}']!)]);
    } else {
      out.add([..._u16(item.mime), 0, ns, ..._u32(0), ..._u32(item.cluster), ..._u32(item.blob)]);
    }
    out
      ..add(utf8.encode(item.path))
      ..addByte(0)
      ..addByte(0); // empty title: same as the path
  }
  final pathPtrPos = out.length;
  for (final o in direntOffsets) {
    out.add(_u64(o));
  }
  final cluster0 = out.length;
  out
    ..addByte(1)
    ..add(clusterBody(plain));
  final cluster1 = out.length;
  out
    ..addByte(5)
    ..add(ZstdCodec.compress(Uint8List.fromList(clusterBody(zstd))));
  final clusterPtrPos = out.length;
  out
    ..add(_u64(cluster0))
    ..add(_u64(cluster1));
  final checksumPos = out.length;
  out.add(Uint8List(16));

  final bytes = out.toBytes();
  ByteData.sublistView(bytes, 0, 80)
    ..setUint32(0, 0x044d495a, Endian.little)
    ..setUint16(4, 6, Endian.little)
    ..setUint16(6, 3, Endian.little)
    ..setUint32(24, items.length, Endian.little)
    ..setUint32(28, 2, Endian.little)
    ..setUint64(32, pathPtrPos, Endian.little)
    ..setUint64(40, 0xffffffffffffffff, Endian.little)
    ..setUint64(48, clusterPtrPos, Endian.little)
    ..setUint64(56, mimeListPos, Endian.little)
    ..setUint32(64, 0xffffffff, Endian.little)
    ..setUint32(68, 0xffffffff, Endian.little)
    ..setUint64(72, checksumPos, Endian.little);
  return bytes;
}

void main() {
  late Directory dir;
  late ZimArchive archive;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('zim_test');
    final file = File('${dir.path}/test.zim')
      ..writeAsBytesSync(buildZim(
        {
          '树艾': '<html><table class="infobox"><tr><td>界：植物界</td></tr></table>'
              '<p><b>树艾</b>（学名：<i>Artemisia arborescens</i>）是菊科蒿属的植物，原产地中海地区。<sup>[1]</sup></p>'
              '<p>叶银灰色，花黄色。</p><script>var x = 1;</script></html>',
          '氢': '<p>氢是一种化学元素。</p>',
          '氢气': '<p>氢气是氢的单质。</p>',
        },
        {'Artemisia arborescens': '树艾', 'Hydrogen': '氢'},
        {'Title': '测试维基', 'Language': 'zho', 'Flavour': 'mini'},
      ));
    archive = await ZimArchive.open(file);
  });

  tearDown(() async {
    await archive.close();
    dir.deleteSync(recursive: true);
  });

  test('reads the header, metadata and title index', () async {
    expect(archive.entryCount, 9);
    expect(archive.hasTitleIndex, isTrue);
    expect(await archive.metadata(),
        {'Title': '测试维基', 'Language': 'zho', 'Flavour': 'mini'});
  });

  test('finds an article by title and reads it from a zstd cluster', () async {
    final entry = (await archive.findByTitle('树艾'))!;
    expect(archive.mimeTypeOf(entry), 'text/html');
    expect(utf8.decode(await archive.content(entry)), contains('Artemisia arborescens'));
  });

  test('a redirect leads to its article', () async {
    final redirect = (await archive.findByTitle('Artemisia arborescens'))!;
    expect(redirect.isRedirect, isTrue);
    expect((await archive.resolve(redirect)).title, '树艾');
  });

  test('paths, prefixes and misses', () async {
    expect((await archive.findByPath('C', '氢'))!.title, '氢');
    expect((await archive.titlesStartingWith('氢')).map((e) => e.title), ['氢', '氢气']);
    expect(await archive.findByTitle('不存在'), isNull);
    expect(await archive.findByPath('C', 'zzz'), isNull);
  });

  test('an article reduces to its lead paragraphs', () async {
    final entry = await archive.resolve((await archive.findByTitle('Artemisia arborescens'))!);
    expect(articleLeadText(utf8.decode(await archive.content(entry))),
        '树艾（学名：Artemisia arborescens）是菊科蒿属的植物，原产地中海地区。\n叶银灰色，花黄色。');
  });

  test('not a ZIM file', () async {
    final bogus = File('${dir.path}/bogus.zim')..writeAsBytesSync(List.filled(200, 7));
    expect(() => ZimArchive.open(bogus), throwsA(isA<ZimFormatException>()));
  });

  // Against a real Kiwix file when one is given:
  // ANX_TEST_ZIM=/path/to/wikipedia_zh_chemistry_mini_2026-06.zim flutter test ...
  final realPath = Platform.environment['ANX_TEST_ZIM'];
  test('a real Kiwix Chinese Wikipedia file', () async {
    final real = await ZimArchive.open(File(realPath!));
    try {
      expect((await real.metadata())['Language'], 'zho');
      final hydrogen = (await real.findByTitle('氢'))!;
      final lead = articleLeadText(utf8.decode(await real.content(hydrogen)));
      expect(lead, contains('氫'));
      final viaRedirect = await real.resolve((await real.findByTitle('Hydrogen'))!);
      expect(viaRedirect.path, hydrogen.path);
      // ignore: avoid_print
      print('real file: ${real.entryCount} entries; lead: ${lead.substring(0, lead.length < 80 ? lead.length : 80)}');
    } finally {
      await real.close();
    }
  }, skip: realPath == null ? 'set ANX_TEST_ZIM to run against a real file' : false);
}
