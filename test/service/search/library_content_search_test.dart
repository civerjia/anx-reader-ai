import 'package:anx_reader/service/search/library_content_search.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('matches keep their chapter and excerpt in order', () {
    final matches = matchesFromSearchResult({
      'results': [
        {
          'chapterTitle': '第三章 矿物与生命',
          'chapterCfi': 'epubcfi(/6/8)',
          'matches': [
            {'cfi': 'epubcfi(/6/8!/4/2)', 'pre': '炽热的', 'match': '岩石泥', 'post': '从裂缝中渗出'},
            {'cfi': 'epubcfi(/6/8!/4/9)', 'pre': '', 'match': '岩石泥', 'post': '冷却后'},
          ],
        },
        {
          'chapterTitle': '第四章',
          'matches': [
            {'cfi': 'epubcfi(/6/10!/4/1)', 'pre': '又见', 'match': '岩石泥', 'post': ''},
          ],
        },
      ],
    });

    expect(matches, hasLength(3));
    expect(matches.first.chapter, '第三章 矿物与生命');
    expect(matches.first.pre + matches.first.match + matches.first.post,
        '炽热的岩石泥从裂缝中渗出');
    expect(matches.last.chapter, '第四章');
  });

  test('a match without a location or text cannot be opened and is dropped', () {
    final matches = matchesFromSearchResult({
      'results': [
        {
          'chapterTitle': 'x',
          'matches': [
            {'cfi': '', 'match': '岩石'},
            {'cfi': 'epubcfi(/6/2)', 'match': '   '},
            'not a map',
          ],
        },
      ],
    });
    expect(matches, isEmpty);
  });

  test('a book with no results yields no matches', () {
    expect(matchesFromSearchResult({'results': []}), isEmpty);
    expect(matchesFromSearchResult({}), isEmpty);
  });
}
