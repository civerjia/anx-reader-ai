import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/service/ai/tools/repository/books_repository.dart';
import 'package:anx_reader/service/library_index/epub_text.dart';
import 'package:anx_reader/service/library_index/library_index_store.dart';
import 'package:anx_reader/utils/get_path/databases_path.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

@immutable
class LibraryIndexStatus {
  const LibraryIndexStatus({
    this.running = false,
    this.done = 0,
    this.total = 0,
    this.title = '',
  });

  final bool running;
  final int done;
  final int total;

  /// The book being indexed.
  final String title;
}

typedef _Job = ({int id, String path, String signature, String title});

/// The library's full-text index: kept in its own database file beside the
/// app's (which is synced, and this need not be), built off the UI isolate.
class LibraryIndex {
  LibraryIndex._();
  static final LibraryIndex instance = LibraryIndex._();

  final ValueNotifier<LibraryIndexStatus> status =
      ValueNotifier(const LibraryIndexStatus());
  Future<void>? _running;

  Future<String> _databasePath() async =>
      p.join(await getAnxDataBasesPath(), 'library_index.db');

  Future<List<Book>> _books() async =>
      (await const BooksRepository().searchBooks(limit: 1 << 30))
          .map((result) => result.book)
          .toList();

  /// Indexes books that are new or changed since, and forgets deleted ones.
  Future<void> updateAll() => _running ??= _update().whenComplete(() {
        _running = null;
        status.value = const LibraryIndexStatus();
      });

  /// [updateAll], but only once the reader has built the index at least once.
  Future<void> updateIfBuilt() async {
    if ((await stats()).books > 0) await updateAll();
  }

  Future<void> _update() async {
    final jobs = <_Job>[];
    for (final book in await _books()) {
      final path = book.fileFullPath;
      if (!path.toLowerCase().endsWith('.epub')) continue;
      final file = File(path);
      if (!file.existsSync()) continue;
      final stat = file.statSync();
      jobs.add((
        id: book.id,
        path: path,
        signature: '${stat.size}:${stat.modified.millisecondsSinceEpoch}',
        title: book.title,
      ));
    }
    final dbPath = await _databasePath();
    final port = ReceivePort();
    final watch = Stopwatch()..start();
    port.listen((message) {
      if (message is String) {
        AnxLog.info('LibraryIndex: $message');
      } else if (message is (int, int, String)) {
        status.value = LibraryIndexStatus(
            running: true, done: message.$1, total: message.$2, title: message.$3);
      }
    });
    status.value = LibraryIndexStatus(running: true, total: jobs.length);
    try {
      await Isolate.run(() => _build(dbPath, jobs, port.sendPort));
    } finally {
      port.close();
    }
    AnxLog.info('LibraryIndex: update finished in ${watch.elapsed.inSeconds} s');
  }

  static void _build(String dbPath, List<_Job> jobs, SendPort out) {
    final store = LibraryIndexStore.open(dbPath);
    try {
      final known = store.signatures();
      final wanted = {for (final job in jobs) job.id};
      for (final id in known.keys.where((id) => !wanted.contains(id))) {
        store.removeBook(id);
        out.send('removed book $id');
      }
      final todo =
          jobs.where((job) => known[job.id] != job.signature).toList();
      for (var i = 0; i < todo.length; i++) {
        final job = todo[i];
        out.send((i, todo.length, job.title));
        final watch = Stopwatch()..start();
        try {
          final sections = readEpubSections(job.path);
          final chunks = store.addBook(job.id, job.signature, sections);
          out.send('indexed #${job.id} ${job.title}: ${sections.length} '
              'documents, $chunks passages in ${watch.elapsedMilliseconds} ms');
        } catch (e) {
          out.send('could not index #${job.id} ${job.title}: $e');
        }
      }
      out.send((todo.length, todo.length, ''));
    } finally {
      store.dispose();
    }
  }

  /// Books and passages indexed, and the index file's size.
  Future<({int books, int chunks, int bytes})> stats() async {
    final dbPath = await _databasePath();
    if (!File(dbPath).existsSync()) return (books: 0, chunks: 0, bytes: 0);
    final counts = await Isolate.run(() {
      final store = LibraryIndexStore.open(dbPath);
      try {
        return store.counts();
      } finally {
        store.dispose();
      }
    });
    var bytes = 0;
    for (final suffix in ['', '-wal']) {
      final file = File('$dbPath$suffix');
      if (file.existsSync()) bytes += file.lengthSync();
    }
    return (books: counts.books, chunks: counts.chunks, bytes: bytes);
  }

  /// Ids of the books in the index.
  Future<Set<int>> indexedBookIds() async {
    final dbPath = await _databasePath();
    if (!File(dbPath).existsSync()) return const {};
    return Isolate.run(() {
      final store = LibraryIndexStore.open(dbPath);
      try {
        return store.signatures().keys.toSet();
      } finally {
        store.dispose();
      }
    });
  }

  /// The passages best matching [query], across the library or in [bookId].
  Future<List<(LibraryPassage, String)>> search(String query,
      {int? bookId, int limit = 5}) async {
    final dbPath = await _databasePath();
    if (!File(dbPath).existsSync()) return const [];
    final books = await _books();
    final paths = {for (final b in books) b.id: b.fileFullPath};
    final titles = {for (final b in books) b.id: b.title};
    final watch = Stopwatch()..start();
    final passages = await Isolate.run(() {
      final store = LibraryIndexStore.open(dbPath);
      try {
        return searchLibrary(store, query, paths, bookId: bookId, limit: limit);
      } finally {
        store.dispose();
      }
    });
    AnxLog.info('LibraryIndex: "$query"${bookId == null ? '' : ' in #$bookId'} '
        '-> ${passages.length} passages in ${watch.elapsedMilliseconds} ms');
    return [for (final passage in passages) (passage, titles[passage.bookId] ?? '')];
  }
}
