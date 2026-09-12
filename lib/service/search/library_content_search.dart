import 'dart:async';

import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/service/ai/tools/input/book_content_search_input.dart';
import 'package:anx_reader/service/ai/tools/repository/book_content_search_repository.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One place a keyword was found in a book's text.
class LibraryContentMatch {
  const LibraryContentMatch({
    required this.chapter,
    required this.cfi,
    required this.pre,
    required this.match,
    required this.post,
  });

  final String chapter;
  final String cfi;
  final String pre;
  final String match;
  final String post;
}

class LibraryContentHit {
  const LibraryContentHit(this.book, this.matches);
  final Book book;
  final List<LibraryContentMatch> matches;
}

class LibraryContentProgress {
  const LibraryContentProgress({
    required this.scanned,
    required this.total,
    required this.hits,
    this.done = false,
  });

  final int scanned;
  final int total;
  final List<LibraryContentHit> hits;
  final bool done;
}

/// Searches the text of every book on the shelf, one book at a time.
///
/// Search inside a book already existed; searching the library did not, and
/// there is no full-text index to query. So each book is opened in a headless
/// reader and searched the way the in-book search does it. That is slow for a
/// large shelf, which is why it runs only when asked, reports progress after
/// every book, and can be stopped.
class LibraryContentSearch {
  LibraryContentSearch(this.ref);

  final WidgetRef ref;
  bool _cancelled = false;

  bool get cancelled => _cancelled;

  /// Takes effect once the book being searched finishes.
  void cancel() => _cancelled = true;

  Stream<LibraryContentProgress> run(String keyword) async* {
    // Idle timeout zero: each headless reader is freed as soon as its book is
    // searched. The repository's default keeps one alive for three minutes,
    // which across a whole shelf would mean dozens of web views at once.
    final repository = BookContentSearchRepository(
      ref: ref,
      searchTimeout: const Duration(seconds: 20),
      sessionIdleTimeout: Duration.zero,
    );
    final books = orderForContentSearch(await bookDao.selectNotDeleteBooks());
    final hits = <LibraryContentHit>[];
    var scanned = 0;
    yield LibraryContentProgress(scanned: 0, total: books.length, hits: const []);

    for (final book in books) {
      if (_cancelled) break;
      try {
        final result = await repository.search(BookContentSearchInput(
          bookId: book.id,
          keyword: keyword,
          maxResults: 5,
          maxSnippets: 2,
          maxCharacters: 100,
        ));
        final matches = matchesFromSearchResult(result);
        if (matches.isNotEmpty) hits.add(LibraryContentHit(book, matches));
      } catch (e) {
        // A book that cannot be opened or searched is skipped, not fatal.
        AnxLog.info('Library search skipped "${book.title}": $e');
      }
      scanned++;
      yield LibraryContentProgress(
        scanned: scanned,
        total: books.length,
        hits: List.unmodifiable(hits),
      );
    }

    yield LibraryContentProgress(
      scanned: scanned,
      total: books.length,
      hits: List.unmodifiable(hits),
      done: true,
    );
  }
}

/// Books most recently read first: where a reader expects to find a passage
/// they half remember, and so where results should arrive soonest.
@visibleForTesting
List<Book> orderForContentSearch(List<Book> books) =>
    books.where((book) => !book.isDeleted).toList()
      ..sort((a, b) => b.updateTime.compareTo(a.updateTime));

/// Flattens a book search result into matches, keeping each match's chapter.
@visibleForTesting
List<LibraryContentMatch> matchesFromSearchResult(Map<String, dynamic> result) {
  final out = <LibraryContentMatch>[];
  for (final chapter in (result['results'] as List? ?? const [])) {
    if (chapter is! Map) continue;
    final title = (chapter['chapterTitle'] as String? ?? '').trim();
    for (final match in (chapter['matches'] as List? ?? const [])) {
      if (match is! Map) continue;
      final cfi = (match['cfi'] as String? ?? '').trim();
      final text = (match['match'] as String? ?? '').trim();
      if (cfi.isEmpty || text.isEmpty) continue;
      out.add(LibraryContentMatch(
        chapter: title,
        cfi: cfi,
        pre: (match['pre'] as String? ?? '').trimLeft(),
        match: text,
        post: (match['post'] as String? ?? '').trimRight(),
      ));
    }
  }
  return out;
}
