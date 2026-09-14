import 'dart:io';
import 'dart:isolate';

import 'package:anx_reader/service/library_index/library_index.dart';
import 'package:anx_reader/service/library_index/library_index_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'library_index_store_test.dart' show makeEpub;

void main() {
  test('builds the index on another isolate and reports progress', () async {
    final dir = Directory.systemTemp.createTempSync('library_index_isolate');
    addTearDown(() => dir.deleteSync(recursive: true));
    final book = makeEpub(dir, 'b.epub', [
      ('第一章', ['林特·艾萨克的日记写在一本旧册子里。']),
    ]);
    final dbPath = '${dir.path}/index.db';
    final port = ReceivePort();
    final messages = <Object?>[];
    port.listen(messages.add);

    await LibraryIndex.buildInIsolate(
      dbPath,
      [(id: 7, path: book.path, signature: 's1', title: '书')],
      port.sendPort,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    port.close();

    expect(messages.whereType<String>().join('\n'), contains('indexed #7'));
    final store = LibraryIndexStore.open(dbPath);
    addTearDown(store.dispose);
    expect(store.signatures(), {7: 's1'});
    expect(searchLibrary(store, '林特', {7: book.path}).single.bookId, 7);
  });
}
