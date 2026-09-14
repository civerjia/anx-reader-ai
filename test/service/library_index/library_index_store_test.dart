import 'dart:convert';
import 'dart:io';

import 'package:anx_reader/service/library_index/epub_text.dart';
import 'package:anx_reader/service/library_index/library_index_store.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// A minimal EPUB 3 with a nav document and [chapters] as (title, paragraphs).
File makeEpub(Directory dir, String name, List<(String, List<String>)> chapters) {
  final archive = Archive();
  void add(String path, String text) {
    final bytes = utf8.encode(text);
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  }

  add('mimetype', 'application/epub+zip');
  add('META-INF/container.xml',
      '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
      '<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>');
  final items = StringBuffer(
      '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>');
  final spine = StringBuffer();
  final nav = StringBuffer();
  for (var i = 0; i < chapters.length; i++) {
    final (title, paragraphs) = chapters[i];
    items.write('<item id="c$i" href="text/c$i.xhtml" media-type="application/xhtml+xml"/>');
    spine.write('<itemref idref="c$i"/>');
    nav.write('<li><a href="text/c$i.xhtml">$title</a></li>');
    add('OEBPS/text/c$i.xhtml',
        '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>x</title><style>p{}</style></head>'
        '<body><h2>$title</h2>${paragraphs.map((p) => '<p>$p</p>').join()}</body></html>');
  }
  add('OEBPS/content.opf',
      '<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0">'
      '<manifest>$items</manifest><spine>$spine</spine></package>');
  add('OEBPS/nav.xhtml',
      '<html xmlns="http://www.w3.org/1999/xhtml"><body><nav epub:type="toc"><ol>$nav</ol></nav></body></html>');
  final file = File('${dir.path}/$name')
    ..writeAsBytesSync(ZipEncoder().encode(archive)!);
  return file;
}

void main() {
  late Directory dir;
  late File novel;
  late File other;

  setUpAll(() {
    dir = Directory.systemTemp.createTempSync('library_index_test');
    novel = makeEpub(dir, 'novel.epub', [
      ('第一章 相遇', ['魔王在城堡里醒来。', '他想起了往事。']),
      ('第二章 日记', [
        for (var i = 0; i < 40; i++) '这是一段填充文字，用来让章节足够长。',
        '林特·艾萨克的日记写在一本旧册子里。',
      ]),
    ]);
    other = makeEpub(dir, 'other.epub', [
      ('序', ['艾萨克是一位老人，住在山里。']),
    ]);
  });
  tearDownAll(() => dir.deleteSync(recursive: true));

  test('reads the spine in order with titles and paragraph text', () {
    final sections = readEpubSections(novel.path);
    expect(sections, hasLength(2));
    expect(sections[0].title, '第一章 相遇');
    expect(sections[0].text, '第一章 相遇\n魔王在城堡里醒来。\n他想起了往事。');
    expect(sections[1].text, contains('林特·艾萨克的日记'));
    final partial = readEpubSections(novel.path, only: {1});
    expect(partial[0].text, isEmpty);
    expect(partial[1].text, sections[1].text);
  });

  test('passages cover the text without gaps', () {
    final section = readEpubSections(novel.path)[1];
    final chunks = chunkSection(section, size: 200);
    expect(chunks.length, greaterThan(1));
    expect(chunks.first.start, 0);
    for (var i = 1; i < chunks.length; i++) {
      expect(chunks[i].start, chunks[i - 1].end);
    }
    expect(chunks.last.end, section.text.length);
  });

  test('finds, ranks, filters by book, and forgets removed books', () {
    final store = LibraryIndexStore(sqlite3.openInMemory());
    addTearDown(store.dispose);
    store.addBook(1, 'a', readEpubSections(novel.path), chunkSize: 200);
    store.addBook(2, 'b', readEpubSections(other.path), chunkSize: 200);
    final paths = {1: novel.path, 2: other.path};

    final both = searchLibrary(store, '林特·艾萨克', paths);
    expect(both.first.bookId, 1);
    expect(both.first.chapter, '第二章 日记');
    expect(both.first.text, contains('林特·艾萨克的日记'));
    expect(both.map((p) => p.bookId), contains(2)); // 艾萨克 alone

    expect(searchLibrary(store, '艾萨克', paths, bookId: 2).single.bookId, 2);
    expect(searchLibrary(store, '不存在的词语', paths), isEmpty);

    store.removeBook(1);
    expect(store.counts().books, 1);
    expect(searchLibrary(store, '林特', paths), isEmpty);
    expect(store.signatures(), {2: 'b'});
  });
}
