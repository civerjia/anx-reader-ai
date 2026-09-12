import 'dart:io';

import 'package:anx_reader/service/knowledge/kiwix_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The Chinese Wikipedia section of the Kiwix catalog as fetched on 2026-09-12.
  final xml = File('test/fixtures/kiwix_catalog_zh.xml').readAsStringSync();

  test('every entry with a ZIM download becomes a pack', () {
    final packs = parseKiwixCatalog(xml);
    expect(packs, hasLength(31));
    expect(packs.every((pack) => pack.downloadUrl.path.endsWith('.zim')), isTrue);
  });

  test('the whole Chinese Wikipedia, lead sections only', () {
    final pack = parseKiwixCatalog(xml)
        .singleWhere((p) => p.name == 'wikipedia_zh_all' && p.flavour == 'mini');
    expect(pack.language, 'zho');
    expect(pack.articleCount, 3505388);
    expect(pack.approximateSize, 4828333056);
    expect(pack.updated, DateTime.utc(2026, 7, 23));
    expect(pack.fileName, 'wikipedia_zh_all_mini_2026-07b.zim');
    expect(pack.downloadUrl.host, 'lb.download.kiwix.org');
  });

  test('names come from the entry, not its author or publisher', () {
    final names = parseKiwixCatalog(xml).map((p) => p.name).toSet();
    expect(names, isNot(contains('Wikipedia')));
    expect(names, isNot(contains('openZIM')));
    expect(names, contains('wikipedia_zh_top'));
  });

  test('the catalog query', () {
    final url = kiwixCatalogUrl();
    expect(url.toString(),
        'https://library.kiwix.org/catalog/v2/entries?lang=zho&category=wikipedia&count=500');
  });
}
