import 'dart:math' as math;

import 'package:anx_reader/service/library_index/epub_text.dart';
import 'package:anx_reader/service/library_index/index_terms.dart';
import 'package:sqlite3/sqlite3.dart';

/// A passage found in the library, with its text read back from the book.
class LibraryPassage {
  const LibraryPassage({
    required this.bookId,
    required this.section,
    required this.chapter,
    required this.text,
    required this.score,
  });

  final int bookId;
  final int section;
  final String chapter;
  final String text;
  final double score;

  Map<String, Object?> toMap({String? bookTitle}) => {
        'book_id': bookId,
        if (bookTitle != null) 'book_title': bookTitle,
        'chapter': chapter,
        'text': text,
      };
}

/// The full-text index of the library: where each passage is, and its terms.
///
/// Only positions are stored — book, spine document, character range — never
/// the text, which is read back from the EPUB for the few passages a search
/// returns. The terms go into a contentless FTS5 table that keeps no positions
/// (`detail=none`). Measured on a 5.1-million-character novel: 6 MB of index,
/// built in under two seconds on a Mac.
class LibraryIndexStore {
  LibraryIndexStore(this.db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS books(
        book_id INTEGER PRIMARY KEY, signature TEXT NOT NULL,
        chunks INTEGER NOT NULL, indexed_at INTEGER NOT NULL)''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS chunks(
        id INTEGER PRIMARY KEY, book_id INTEGER NOT NULL,
        section INTEGER NOT NULL, start INTEGER NOT NULL, "end" INTEGER NOT NULL)''');
    db.execute('CREATE INDEX IF NOT EXISTS chunks_book ON chunks(book_id)');
    db.execute('''
      CREATE VIRTUAL TABLE IF NOT EXISTS chunk_fts USING fts5(
        terms, content='', contentless_delete=1, detail=none,
        tokenize='unicode61')''');
  }

  factory LibraryIndexStore.open(String path) =>
      LibraryIndexStore(sqlite3.open(path));

  final Database db;

  void dispose() => db.dispose();

  /// Signature of each indexed book, by id.
  Map<int, String> signatures() => {
        for (final row in db.select('SELECT book_id, signature FROM books'))
          row['book_id'] as int: row['signature'] as String,
      };

  ({int books, int chunks}) counts() {
    final row = db.select(
        'SELECT (SELECT count(*) FROM books) AS b, (SELECT count(*) FROM chunks) AS c')
        .first;
    return (books: row['b'] as int, chunks: row['c'] as int);
  }

  void removeBook(int bookId) {
    db.execute('BEGIN');
    try {
      _remove(bookId);
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  void _remove(int bookId) {
    db.execute(
        'DELETE FROM chunk_fts WHERE rowid IN (SELECT id FROM chunks WHERE book_id = ?)',
        [bookId]);
    db.execute('DELETE FROM chunks WHERE book_id = ?', [bookId]);
    db.execute('DELETE FROM books WHERE book_id = ?', [bookId]);
  }

  /// Replaces whatever is indexed for [bookId] with [sections]. Returns the
  /// number of passages.
  int addBook(int bookId, String signature, List<EpubSection> sections,
      {int chunkSize = 1000}) {
    db.execute('BEGIN');
    try {
      _remove(bookId);
      final insertChunk = db.prepare(
          'INSERT INTO chunks(book_id, section, start, "end") VALUES (?, ?, ?, ?)');
      final insertTerms =
          db.prepare('INSERT INTO chunk_fts(rowid, terms) VALUES (?, ?)');
      var count = 0;
      try {
        for (final section in sections) {
          for (final chunk in chunkSection(section, size: chunkSize)) {
            insertChunk.execute([bookId, chunk.section, chunk.start, chunk.end]);
            insertTerms.execute([
              db.lastInsertRowId,
              indexTermsOf(section.text.substring(chunk.start, chunk.end)),
            ]);
            count++;
          }
        }
      } finally {
        insertChunk.dispose();
        insertTerms.dispose();
      }
      db.execute(
          'INSERT INTO books(book_id, signature, chunks, indexed_at) VALUES (?, ?, ?, ?)',
          [bookId, signature, count, DateTime.now().millisecondsSinceEpoch]);
      db.execute('COMMIT');
      return count;
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Passages whose terms match [query], best first by BM25: all terms if any
  /// passage has them all, otherwise any of them.
  List<({int bookId, int section, int start, int end})> candidates(
    String query, {
    int? bookId,
    int limit = 60,
  }) {
    final terms = queryTermsOf(query);
    if (terms.isEmpty) return const [];
    String quoted(String t) => t.runes.length == 1 && isCjkRune(t.runes.first)
        ? '"$t"*'
        : '"$t"';
    final seen = <int>{};
    final found = <({int bookId, int section, int start, int end})>[];
    for (final join in [' AND ', ' OR ']) {
      if (found.length >= limit ~/ 3) break;
      if (join == ' OR ' && terms.length == 1) break;
      final rows = db.select(
        'SELECT c.id, c.book_id, c.section, c.start, c."end" '
        'FROM chunk_fts JOIN chunks c ON c.id = chunk_fts.rowid '
        'WHERE chunk_fts MATCH ? ${bookId == null ? '' : 'AND c.book_id = ?'} '
        'ORDER BY bm25(chunk_fts) LIMIT ?',
        [terms.map(quoted).join(join), if (bookId != null) bookId, limit],
      );
      for (final row in rows) {
        if (!seen.add(row['id'] as int)) continue;
        found.add((
          bookId: row['book_id'] as int,
          section: row['section'] as int,
          start: row['start'] as int,
          end: row['end'] as int,
        ));
      }
    }
    return found;
  }
}

/// Searches the index and reads the passages back from the books at [paths]:
/// ranked by how many query terms each holds, the whole query as one phrase
/// counting most, with at most [perBook] from any one book.
List<LibraryPassage> searchLibrary(
  LibraryIndexStore store,
  String query,
  Map<int, String> paths, {
  int? bookId,
  int limit = 5,
  int perBook = 3,
  int snippet = 320,
}) {
  final hits = store.candidates(query, bookId: bookId);
  if (hits.isEmpty) return const [];
  final terms = queryTermsOf(query);
  final phrase = squashed(query);

  final bySectionOfBook = <int, Set<int>>{};
  for (final hit in hits) {
    (bySectionOfBook[hit.bookId] ??= {}).add(hit.section);
  }
  final sectionsOfBook = <int, List<EpubSection>>{};
  for (final MapEntry(key: id, value: sections) in bySectionOfBook.entries) {
    final path = paths[id];
    if (path == null) continue;
    try {
      sectionsOfBook[id] = readEpubSections(path, only: sections);
    } catch (_) {
      // A book that can no longer be read contributes nothing.
    }
  }

  final scored = <LibraryPassage>[];
  for (var rank = 0; rank < hits.length; rank++) {
    final hit = hits[rank];
    final sections = sectionsOfBook[hit.bookId];
    if (sections == null || hit.section >= sections.length) continue;
    final section = sections[hit.section];
    if (hit.end > section.text.length) continue; // the book changed since
    final text = section.text.substring(hit.start, hit.end);
    final lower = text.toLowerCase();
    final covered = terms.where(lower.contains).length;
    final whole = phrase.isNotEmpty && squashed(text).contains(phrase);
    final score = (whole ? 3.0 : 0.0) +
        (terms.isEmpty ? 0 : 2.0 * covered / terms.length) -
        rank / hits.length;

    // A window around the first place the query shows up.
    var at = -1;
    for (final term in [if (phrase.isNotEmpty) query.trim(), ...terms]) {
      at = lower.indexOf(term.toLowerCase());
      if (at >= 0) break;
    }
    final from = math.max(0, (at < 0 ? 0 : at) - snippet ~/ 3);
    final to = math.min(text.length, from + snippet);
    scored.add(LibraryPassage(
      bookId: hit.bookId,
      section: hit.section,
      chapter: section.title,
      text: '${from > 0 ? '…' : ''}${text.substring(from, to).trim()}'
          '${to < text.length ? '…' : ''}',
      score: score,
    ));
  }
  scored.sort((a, b) => b.score.compareTo(a.score));
  final perBookCount = <int, int>{};
  return [
    for (final passage in scored)
      if ((perBookCount[passage.bookId] =
              (perBookCount[passage.bookId] ?? 0) + 1) <=
          perBook)
        passage,
  ].take(limit).toList();
}
