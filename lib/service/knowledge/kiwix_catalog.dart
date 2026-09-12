import 'package:xml/xml.dart';

/// One downloadable knowledge pack listed by the Kiwix library.
class KiwixPack {
  const KiwixPack({
    required this.name,
    required this.flavour,
    required this.title,
    required this.summary,
    required this.language,
    required this.updated,
    required this.articleCount,
    required this.approximateSize,
    required this.downloadUrl,
  });

  /// Stable identity across releases, e.g. `wikipedia_zh_all`.
  final String name;

  /// `mini` (lead sections only), `nopic` (full text) or `maxi` (with media).
  final String flavour;
  final String title;
  final String summary;
  final String language;
  final DateTime? updated;
  final int articleCount;

  /// The catalog's size, rounded up by the catalog; the server's length is exact.
  final int approximateSize;

  /// The .zim file itself (the catalog links a metalink next to it).
  final Uri downloadUrl;

  /// The file name the release is published under.
  String get fileName => downloadUrl.pathSegments.last;

  @override
  String toString() => 'KiwixPack($name, $flavour, $approximateSize bytes)';
}

/// The Kiwix OPDS catalog query for Wikipedia packs in [language] (ISO 639-3).
Uri kiwixCatalogUrl({String language = 'zho', String category = 'wikipedia'}) =>
    Uri.https('library.kiwix.org', '/catalog/v2/entries', {
      'lang': language,
      'category': category,
      'count': '500',
    });

/// Packs in a Kiwix OPDS catalog feed, skipping entries without a ZIM download.
List<KiwixPack> parseKiwixCatalog(String xml) {
  final document = XmlDocument.parse(xml);
  final packs = <KiwixPack>[];
  for (final entry in document.rootElement.childElements
      .where((element) => element.localName == 'entry')) {
    // Only direct children: the author and publisher have <name> elements too.
    String text(String localName) =>
        entry.childElements
            .where((element) => element.localName == localName)
            .map((element) => element.innerText.trim())
            .firstOrNull ??
        '';

    XmlElement? download;
    for (final link in entry.childElements.where((e) => e.localName == 'link')) {
      final rel = link.getAttribute('rel') ?? '';
      final type = link.getAttribute('type') ?? '';
      if (rel.startsWith('http://opds-spec.org/acquisition') &&
          type == 'application/x-zim') {
        download = link;
        break;
      }
    }
    final href = download?.getAttribute('href');
    if (href == null || href.isEmpty) continue;
    final zimHref =
        href.endsWith('.meta4') ? href.substring(0, href.length - 6) : href;
    final url = Uri.tryParse(zimHref);
    if (url == null) continue;

    packs.add(KiwixPack(
      name: text('name'),
      flavour: text('flavour'),
      title: text('title'),
      summary: text('summary'),
      language: text('language'),
      updated: DateTime.tryParse(text('updated')),
      articleCount: int.tryParse(text('articleCount')) ?? 0,
      approximateSize: int.tryParse(download?.getAttribute('length') ?? '') ?? 0,
      downloadUrl: url,
    ));
  }
  return packs;
}
