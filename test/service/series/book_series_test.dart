import 'dart:convert';
import 'dart:io';

import 'package:anx_reader/models/book_series.dart';
import 'package:anx_reader/service/series/book_series.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

String opf(String metadata) => '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:title>Book</dc:title>
    $metadata
  </metadata>
</package>''';

int byCodeUnits(String a, String b) => a.compareTo(b);

void main() {
  group('parseOpfSeries', () {
    test('EPUB 3 series collection with its position', () {
      expect(
        parseOpfSeries(opf('''
          <meta property="belongs-to-collection" id="c01">三体</meta>
          <meta refines="#c01" property="collection-type">series</meta>
          <meta refines="#c01" property="group-position">2</meta>''')),
        const BookSeries('三体', 2),
      );
    });

    test('Calibre metas in an EPUB 2 file', () {
      expect(
        parseOpfSeries(opf('''
          <meta name="calibre:series" content="The Expanse"/>
          <meta name="calibre:series_index" content="3.0"/>''')),
        const BookSeries('The Expanse', 3),
      );
    });

    test('a typed series beats Calibre, which beats an untyped collection', () {
      const untyped = '<meta property="belongs-to-collection">Loose</meta>';
      const calibre = '<meta name="calibre:series" content="Calibre"/>';
      const typed = '''
          <meta property="belongs-to-collection" id="s">Typed</meta>
          <meta refines="#s" property="collection-type">series</meta>''';
      expect(parseOpfSeries(opf('$untyped$calibre$typed'))?.name, 'Typed');
      expect(parseOpfSeries(opf('$untyped$calibre'))?.name, 'Calibre');
      expect(parseOpfSeries(opf(untyped)), const BookSeries('Loose'));
    });

    test('a set is a publisher line, not a series', () {
      expect(
        parseOpfSeries(opf('''
          <meta property="belongs-to-collection" id="p">Penguin Classics</meta>
          <meta refines="#p" property="collection-type">set</meta>''')),
        isNull,
      );
    });

    test('no series, or not XML at all', () {
      expect(parseOpfSeries(opf('')), isNull);
      expect(parseOpfSeries('<package><metadata>'), isNull);
    });

    test('a byte order mark does not hide the series', () {
      expect(
        parseOpfSeries('﻿${opf('<meta name="calibre:series" content="S"/>')}'),
        const BookSeries('S'),
      );
    });
  });

  group('readEpubSeries', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('series_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    String writeZip(String name, Map<String, String> files) {
      final archive = Archive();
      for (final MapEntry(key: path, value: content) in files.entries) {
        final bytes = utf8.encode(content);
        archive.addFile(ArchiveFile(path, bytes.length, bytes));
      }
      final file = File('${dir.path}/$name')
        ..writeAsBytesSync(ZipEncoder().encode(archive)!);
      return file.path;
    }

    test('follows container.xml to the package document', () {
      final path = writeZip('book.epub', {
        'mimetype': 'application/epub+zip',
        'META-INF/container.xml': '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''',
        'OEBPS/content.opf': opf('''
          <meta name="calibre:series" content="Dune"/>
          <meta name="calibre:series_index" content="1"/>'''),
      });
      expect(readEpubSeries(path), const BookSeries('Dune', 1));
    });

    test('unreadable files give null rather than throwing', () {
      final notZip = File('${dir.path}/broken.epub')..writeAsStringSync('nope');
      expect(readEpubSeries(notZip.path), isNull);
      expect(readEpubSeries(writeZip('empty.epub', {'a.txt': 'a'})), isNull);
    });

    test('missing files are left for later; other formats have no series', () {
      final pdf = File('${dir.path}/a.pdf')..writeAsStringSync('%PDF');
      expect(
        readSeriesOfFiles({1: '${dir.path}/gone.epub', 2: pdf.path}),
        {2: null},
      );
    });
  });

  group('compareBySeries', () {
    const a1 = BookSeries('A', 1);
    const a2 = BookSeries('A', 2);
    const aNone = BookSeries('A');
    const b1 = BookSeries('B', 1);

    List<BookSeries?> sorted(List<BookSeries?> items, {bool descending = false}) =>
        [...items]..sort((x, y) => compareBySeries(x, y,
            compareNames: byCodeUnits, descending: descending));

    test('by name, then by place in the series', () {
      expect(sorted([b1, aNone, a2, null, a1]), [a1, a2, aNone, b1, null]);
    });

    test('descending flips the names only', () {
      expect(sorted([a2, null, b1, a1], descending: true), [b1, a1, a2, null]);
    });
  });

  group('planSeriesGroups', () {
    SeriesShelfBook book(int id, String? series, {double? at, int groupId = 0}) =>
        (id: id, groupId: groupId, series: series == null ? null : BookSeries(series, at));

    test('two or more loose books get a folder, in series order', () {
      final plans = planSeriesGroups(
        [book(9, 'Dune', at: 2), book(4, 'Dune', at: 1), book(5, 'Solo'), book(6, null)],
        {},
      );
      expect(plans, hasLength(1));
      expect(plans.single.name, 'Dune');
      expect(plans.single.createNew, isTrue);
      expect(plans.single.bookIds, [4, 9]);
      expect(plans.single.groupId, 4);
    });

    test('an existing folder with the series name takes even one book', () {
      final plans = planSeriesGroups([book(5, 'Solo')], {12: 'Solo'});
      expect(plans.single.groupId, 12);
      expect(plans.single.createNew, isFalse);
      expect(plans.single.bookIds, [5]);
    });

    test('books already in a folder stay put', () {
      final plans = planSeriesGroups(
        [book(1, 'Dune', groupId: 30), book(2, 'Dune')],
        {30: 'Favourites'},
      );
      expect(plans, isEmpty);
    });

    test('a new folder never takes an id that is already a folder', () {
      final plans =
          planSeriesGroups([book(3, 'X', at: 1), book(7, 'X', at: 2)], {3: 'Other'});
      expect(plans.single.groupId, 7);
    });
  });
}
