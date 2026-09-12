import 'dart:io';
import 'dart:typed_data';

import 'package:anx_reader/service/dictionary/bundled_dictionaries.dart';
import 'package:anx_reader/service/dictionary/dictionary_library.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  final loads = <String>[];

  Future<ByteData> fromAssets(String asset) async {
    loads.add(asset);
    return ByteData.sublistView(Uint8List.fromList(File(asset).readAsBytesSync()));
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('bundled_test');
    loads.clear();
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('the shipped English-Chinese dictionary installs and looks words up', () async {
    expect(await installBundledDictionaries(root: root, load: fromAssets), ['ecdict']);
    final library = DictionaryLibrary(root);
    expect((await library.installed()).single.wordCount, greaterThan(50000));
    expect((await library.lookup('went')).first.headword, 'go');
    expect((await library.lookup('quay')).first.definition, contains('码头'));
  });

  test('installs once, and a removed bundled dictionary stays removed', () async {
    await installBundledDictionaries(root: root, load: fromAssets);
    loads.clear();
    expect(await installBundledDictionaries(root: root, load: fromAssets), isEmpty);
    expect(loads, isEmpty);

    final library = DictionaryLibrary(root);
    await library.remove((await library.installed()).single);
    expect(await installBundledDictionaries(root: root, load: fromAssets), isEmpty);
    expect(await library.installed(), isEmpty);
  });

  test('a new version is installed again', () async {
    const v1 = [BundledDictionary('ecdict', 1, ['LICENSE.txt'])];
    const v2 = [BundledDictionary('ecdict', 2, ['LICENSE.txt'])];
    expect(await installBundledDictionaries(root: root, load: fromAssets, dictionaries: v1), ['ecdict']);
    expect(await installBundledDictionaries(root: root, load: fromAssets, dictionaries: v2), ['ecdict']);
  });
}
