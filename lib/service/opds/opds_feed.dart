import 'package:xml/xml.dart';

/// A way to download a book, in one format.
class OpdsAcquisition {
  const OpdsAcquisition({required this.href, required this.type, this.extension});

  final Uri href;
  final String type;

  /// File extension the app imports this format as, or null when the MIME
  /// type is not one the reader knows.
  final String? extension;
}

class OpdsEntry {
  const OpdsEntry({
    required this.id,
    required this.title,
    this.author = '',
    this.summary = '',
    this.navigation,
    this.acquisitions = const [],
    this.cover,
    this.thumbnail,
  });

  final String id;
  final String title;
  final String author;
  final String summary;

  /// Where a navigation entry leads: a shelf, an author, a series, a page.
  final Uri? navigation;

  /// Downloadable formats, most preferred first.
  final List<OpdsAcquisition> acquisitions;
  final Uri? cover;
  final Uri? thumbnail;

  bool get isBook => acquisitions.isNotEmpty;
}

class OpdsFeed {
  const OpdsFeed({
    required this.title,
    required this.entries,
    this.next,
    this.searchTemplate,
    this.openSearchDescription,
  });

  final String title;
  final List<OpdsEntry> entries;

  /// The next page of this feed, when the server paginates.
  final Uri? next;

  /// A search URL with a `{searchTerms}` placeholder, when the feed gives one
  /// directly.
  final String? searchTemplate;

  /// An OpenSearch description to fetch for the template, which is how
  /// Calibre-Web advertises search.
  final Uri? openSearchDescription;
}

/// Formats in the order a reader would rather download them. EPUB reflows and
/// takes highlights; PDF is fixed layout and does not.
const List<String> opdsFormatPreference = [
  'epub',
  'azw3',
  'mobi',
  'fb2',
  'txt',
  'pdf',
  'cbz',
];

const Map<String, String> _extensionForType = {
  'application/epub+zip': 'epub',
  'application/x-mobipocket-ebook': 'mobi',
  'application/x-mobi8-ebook': 'azw3',
  'application/vnd.amazon.ebook': 'azw3',
  'application/x-fictionbook+xml': 'fb2',
  'application/fb2+zip': 'fb2',
  'text/plain': 'txt',
  'application/pdf': 'pdf',
  'application/x-cbz': 'cbz',
  'application/vnd.comicbook+zip': 'cbz',
};

String? extensionForMimeType(String type) {
  final bare = type.split(';').first.trim().toLowerCase();
  return _extensionForType[bare];
}

/// Parses an OPDS 1.x (Atom) feed. Links are resolved against [base], since
/// servers routinely send them relative.
OpdsFeed parseOpdsFeed(String xml, Uri base) {
  final document = XmlDocument.parse(xml);
  final feed = document.rootElement;

  Uri? feedLink(bool Function(String rel, String type, String href) test) {
    for (final link in _children(feed, 'link')) {
      final rel = link.getAttribute('rel') ?? '';
      final type = link.getAttribute('type') ?? '';
      final href = link.getAttribute('href') ?? '';
      if (href.isNotEmpty && test(rel, type, href)) return base.resolve(href);
    }
    return null;
  }

  String? searchTemplate;
  Uri? openSearch;
  for (final link in _children(feed, 'link')) {
    if (link.getAttribute('rel') != 'search') continue;
    final href = link.getAttribute('href') ?? '';
    final type = link.getAttribute('type') ?? '';
    if (href.isEmpty) continue;
    if (href.contains('{searchTerms}')) {
      searchTemplate ??= _resolveTemplate(base, href);
    } else if (type.contains('opensearchdescription')) {
      openSearch ??= base.resolve(href);
    }
  }

  return OpdsFeed(
    title: _text(feed, 'title'),
    entries: [
      for (final entry in _children(feed, 'entry')) _parseEntry(entry, base),
    ],
    next: feedLink((rel, _, __) => rel == 'next'),
    searchTemplate: searchTemplate,
    openSearchDescription: openSearch,
  );
}

/// Pulls the Atom search template out of an OpenSearch description document.
String? parseOpenSearchTemplate(String xml, Uri base) {
  final document = XmlDocument.parse(xml);
  String? fallback;
  for (final url in document.descendants.whereType<XmlElement>()) {
    if (url.name.local != 'Url') continue;
    final template = url.getAttribute('template');
    if (template == null || !template.contains('{searchTerms}')) continue;
    final type = url.getAttribute('type') ?? '';
    final resolved = _resolveTemplate(base, template);
    if (type.contains('atom')) return resolved;
    fallback ??= resolved;
  }
  return fallback;
}

OpdsEntry _parseEntry(XmlElement entry, Uri base) {
  Uri? navigation;
  Uri? cover;
  Uri? thumbnail;
  final acquisitions = <OpdsAcquisition>[];

  for (final link in _children(entry, 'link')) {
    final href = link.getAttribute('href') ?? '';
    if (href.isEmpty) continue;
    final rel = link.getAttribute('rel') ?? '';
    final type = link.getAttribute('type') ?? '';
    final uri = base.resolve(href);

    if (rel.startsWith('http://opds-spec.org/acquisition')) {
      acquisitions.add(OpdsAcquisition(
        href: uri,
        type: type,
        extension: extensionForMimeType(type) ?? _extensionFromPath(uri),
      ));
    } else if (rel.contains('thumbnail')) {
      thumbnail ??= uri;
    } else if (rel == 'http://opds-spec.org/image' ||
        rel == 'http://opds-spec.org/cover' ||
        rel == 'x-stanza-cover-image') {
      cover ??= uri;
    } else if (type.contains('application/atom+xml') &&
        rel != 'self' &&
        rel != 'up' &&
        rel != 'start') {
      navigation ??= uri;
    }
  }

  acquisitions.sort((a, b) => _rank(a.extension).compareTo(_rank(b.extension)));

  final author = _children(entry, 'author')
      .map((a) => _text(a, 'name'))
      .where((name) => name.isNotEmpty)
      .join(', ');
  final summary = _text(entry, 'summary').isNotEmpty
      ? _text(entry, 'summary')
      : _stripTags(_text(entry, 'content'));

  return OpdsEntry(
    id: _text(entry, 'id'),
    title: _text(entry, 'title'),
    author: author,
    summary: summary,
    navigation: acquisitions.isEmpty ? navigation : null,
    acquisitions: acquisitions,
    cover: cover ?? thumbnail,
    thumbnail: thumbnail ?? cover,
  );
}

int _rank(String? extension) {
  final i = extension == null ? -1 : opdsFormatPreference.indexOf(extension);
  return i < 0 ? opdsFormatPreference.length : i;
}

Iterable<XmlElement> _children(XmlElement parent, String localName) =>
    parent.childElements.where((e) => e.name.local == localName);

String _text(XmlElement parent, String localName) {
  for (final e in _children(parent, localName)) {
    return e.innerText.trim();
  }
  return '';
}

String _stripTags(String html) =>
    html.replaceAll(RegExp(r'<[^>]*>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

String? _extensionFromPath(Uri uri) {
  final last = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
  final dot = last.lastIndexOf('.');
  if (dot < 0) return null;
  final ext = last.substring(dot + 1).toLowerCase();
  return opdsFormatPreference.contains(ext) ? ext : null;
}

/// Resolves a template against the feed without percent-encoding the braces
/// of its placeholder.
String _resolveTemplate(Uri base, String template) {
  const marker = 'ANXSEARCHTERMS';
  final resolved = base.resolve(template.replaceAll('{searchTerms}', marker));
  return resolved.toString().replaceAll(marker, '{searchTerms}');
}
