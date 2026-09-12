import 'package:anx_reader/models/opds_catalog.dart';
import 'package:anx_reader/service/opds/opds_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('titles become file names valid on every platform', () {
    expect(safeFileName('地球的故事：从一粒星尘到充满生命的世界'), '地球的故事：从一粒星尘到充满生命的世界');
    expect(safeFileName('a/b\\c:d*e?f"g<h>i|j'), 'a b c d e f g h i j');
    expect(safeFileName('   '), 'book');
    expect(safeFileName('x' * 200).length, 80);
  });

  test('Basic credentials only when a username is set', () {
    const open = OpdsCatalog(id: '1', title: 't', url: 'https://x/opds');
    expect(OpdsClient(open).authorizationHeader, isNull);
    const locked = OpdsCatalog(
        id: '2', title: 't', url: 'https://x/opds', username: 'me', password: 'pw');
    expect(OpdsClient(locked).authorizationHeader, 'Basic bWU6cHc=');
  });

  test('search terms are encoded into the template', () {
    const c = OpdsCatalog(id: '1', title: 't', url: 'https://x/opds');
    expect(
      OpdsClient(c).searchUrl('https://x/opds/search/{searchTerms}', '地球 故事').toString(),
      'https://x/opds/search/%E5%9C%B0%E7%90%83+%E6%95%85%E4%BA%8B',
    );
  });
}
