import 'dart:io';

import 'package:anx_reader/service/ai/tools/knowledge_lookup_tool.dart';
import 'package:anx_reader/service/knowledge/knowledge_library.dart';
import 'package:flutter_test/flutter_test.dart';

import 'zim_archive_test.dart' as zim;

void main() {
  late Directory dir;
  late KnowledgeLibrary library;

  File writePack(String path) => File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(zim.buildZim(
      {
        '树艾': '<p><b>树艾</b>（学名：<i>Artemisia arborescens</i>）是菊科蒿属的植物，原产地中海地区。</p>',
        '氢': '<p>氢是一种化学元素。</p>',
      },
      {'Artemisia arborescens': '树艾'},
      {'Title': '测试维基', 'Language': 'zho', 'Flavour': 'mini', 'Date': '2026-06-16'},
    ));

  setUp(() {
    dir = Directory.systemTemp.createTempSync('knowledge_test');
    library = KnowledgeLibrary(Directory('${dir.path}/library'));
  });

  tearDown(() async {
    await library.refresh();
    dir.deleteSync(recursive: true);
  });

  test('title candidates cover script, capitalisation and underscores', () {
    expect(titleCandidates('artemisia arborescens'),
        containsAll(['artemisia arborescens', 'Artemisia arborescens', 'Artemisia_arborescens']));
    expect(titleCandidates('愛'), contains('爱'));
    expect(titleCandidates('  '), isEmpty);
  });

  test('installed packs, lookup through a redirect, suggestions', () async {
    writePack('${dir.path}/library/test.zim');
    final packs = await library.installed();
    expect(packs.single.title, '测试维基');
    expect(packs.single.flavour, 'mini');

    final found = await library.lookup('artemisia arborescens');
    expect(found.hits.single.title, '树艾');
    expect(found.hits.single.text, contains('菊科蒿属'));
    expect(found.hits.single.pack.title, '测试维基');

    final partial = await library.lookup('树');
    expect(partial.hits, isEmpty);
    expect(partial.suggestions, ['树艾']);
  });

  test('import checks the file, remove deletes it', () async {
    final pack = await library.import(writePack('${dir.path}/elsewhere/new.zim'));
    expect(pack!.title, '测试维基');
    expect(File('${dir.path}/library/new.zim').existsSync(), isTrue);

    final bogus = File('${dir.path}/bogus.zim')..writeAsStringSync('not a zim');
    expect(await library.import(bogus), isNull);

    await library.remove(pack);
    expect(await library.installed(), isEmpty);
  });

  test('the tool answers from the pack, and says when it cannot', () async {
    final tool = KnowledgeLookupTool(library);
    expect((await tool.run(const KnowledgeLookupInput(query: '氢')))['note'],
        contains('No offline encyclopedia'));

    writePack('${dir.path}/library/test.zim');
    await library.refresh();
    final found = await tool.run(const KnowledgeLookupInput(query: 'Artemisia arborescens'));
    expect(found['found'], isTrue);
    expect((found['articles'] as List).single['title'], '树艾');

    final missing = await tool.run(const KnowledgeLookupInput(query: '树'));
    expect(missing['found'], isFalse);
    expect(missing['similar_titles'], ['树艾']);
  });
}
