import 'package:anx_reader/service/opds/opds_feed.dart';
import 'package:flutter_test/flutter_test.dart';

final _base = Uri.parse('https://books.example.com/opds/');

const _navigation = '''<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom" xmlns:opds="http://opds-spec.org/2010/catalog">
  <id>urn:uuid:root</id>
  <title>Calibre-Web</title>
  <link rel="self" href="/opds" type="application/atom+xml;profile=opds-catalog;type=feed;kind=navigation"/>
  <link rel="search" href="/opds/osd" type="application/opensearchdescription+xml"/>
  <entry>
    <title>最近添加</title>
    <id>/opds/new</id>
    <link rel="subsection" href="/opds/new" type="application/atom+xml;profile=opds-catalog;type=feed;kind=acquisition"/>
  </entry>
  <entry>
    <title>作者</title>
    <id>/opds/author</id>
    <link type="application/atom+xml;profile=opds-catalog;type=feed;kind=navigation" href="author"/>
  </entry>
</feed>''';

const _acquisition = '''<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>最近添加</title>
  <link rel="next" href="/opds/new?offset=30" type="application/atom+xml;profile=opds-catalog"/>
  <link rel="search" href="/opds/search/{searchTerms}" type="application/atom+xml"/>
  <entry>
    <title>地球的故事</title>
    <id>urn:uuid:7</id>
    <author><name>罗伯特·哈森</name></author>
    <summary>一部颠覆性的地球传记</summary>
    <link rel="http://opds-spec.org/image/thumbnail" href="/opds/thumb/7"/>
    <link rel="http://opds-spec.org/image" href="/opds/cover/7"/>
    <link rel="http://opds-spec.org/acquisition" type="application/pdf" href="/opds/download/7/pdf/"/>
    <link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="/opds/download/7/epub/"/>
    <link rel="http://opds-spec.org/acquisition/open-access" type="application/x-mobipocket-ebook" href="download/7/mobi/"/>
    <link rel="alternate" type="application/atom+xml" href="/opds/book/7"/>
  </entry>
</feed>''';

void main() {
  test('navigation entries lead somewhere and are not books', () {
    final feed = parseOpdsFeed(_navigation, _base);
    expect(feed.title, 'Calibre-Web');
    expect(feed.entries, hasLength(2));
    expect(feed.entries.every((e) => !e.isBook), isTrue);
    expect(feed.entries[0].navigation.toString(),
        'https://books.example.com/opds/new');
    // A relative href resolves against the feed, not the host root.
    expect(feed.entries[1].navigation.toString(),
        'https://books.example.com/opds/author');
    expect(feed.openSearchDescription.toString(),
        'https://books.example.com/opds/osd');
  });

  test('a book lists formats in preference order with extensions', () {
    final feed = parseOpdsFeed(_acquisition, _base);
    final book = feed.entries.single;
    expect(book.isBook, isTrue);
    expect(book.title, '地球的故事');
    expect(book.author, '罗伯特·哈森');
    expect(book.summary, '一部颠覆性的地球传记');
    expect(book.acquisitions.map((a) => a.extension), ['epub', 'mobi', 'pdf']);
    expect(book.acquisitions.first.href.toString(),
        'https://books.example.com/opds/download/7/epub/');
    // An alternate atom link on a book is not a reason to treat it as a folder.
    expect(book.navigation, isNull);
    expect(book.cover.toString(), 'https://books.example.com/opds/cover/7');
    expect(book.thumbnail.toString(), 'https://books.example.com/opds/thumb/7');
  });

  test('pagination and a direct search template are found', () {
    final feed = parseOpdsFeed(_acquisition, _base);
    expect(feed.next.toString(), 'https://books.example.com/opds/new?offset=30');
    expect(feed.searchTemplate,
        'https://books.example.com/opds/search/{searchTerms}');
  });

  test('an OpenSearch description yields the Atom template', () {
    const osd = '''<?xml version="1.0"?>
<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
  <Url type="text/html" template="/search?q={searchTerms}"/>
  <Url type="application/atom+xml" template="/opds/search?query={searchTerms}"/>
</OpenSearchDescription>''';
    expect(parseOpenSearchTemplate(osd, _base),
        'https://books.example.com/opds/search?query={searchTerms}');
  });

  test('Komga style: acquisition rel with a comic zip', () {
    const komga = '''<feed xmlns="http://www.w3.org/2005/Atom"><title>Series</title>
<entry><title>Vol 1</title><id>b1</id>
<link rel="http://opds-spec.org/acquisition" type="application/vnd.comicbook+zip" href="/api/v1/books/b1/file"/>
</entry></feed>''';
    final book = parseOpdsFeed(komga, Uri.parse('https://komga.local/opds/v1.2/')).entries.single;
    expect(book.acquisitions.single.extension, 'cbz');
  });

  test('an unknown MIME type falls back to the path extension', () {
    expect(extensionForMimeType('application/octet-stream'), isNull);
    const odd = '''<feed xmlns="http://www.w3.org/2005/Atom"><title>x</title>
<entry><title>y</title><id>1</id>
<link rel="http://opds-spec.org/acquisition" type="application/octet-stream" href="/files/y.epub"/>
</entry></feed>''';
    expect(parseOpdsFeed(odd, _base).entries.single.acquisitions.single.extension, 'epub');
  });
}
