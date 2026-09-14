import 'package:anx_reader/providers/current_reading.dart';
import 'package:anx_reader/service/ai/tools/repository/books_repository.dart';
import 'package:anx_reader/service/ai/tools/repository/groups_repository.dart';
import 'package:anx_reader/service/ai/tools/repository/notes_repository.dart';
import 'package:anx_reader/service/ai/tools/repository/reading_history_repository.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Ceilings, so the digest stays a few hundred tokens rather than thousands.
/// Prefill is fast on device — around 200 tok/s — but it is paid on every
/// message, and the context has an answer to fit in too.
const int _shelfLimit = 12;
const int _historyLimit = 12;
const int _noteLimit = 8;
const int _snippetLimit = 90;

/// What the reader's own data looks like, written out for a local model.
///
/// A remote provider answers "which books did I read last week" by calling
/// tools. A 2B model on a phone cannot be relied on to drive a tool loop, so
/// rather than leave it to invent an answer, the data those tools would have
/// returned is assembled up front and handed over with the question.
///
/// Returns null when there is nothing to say, so no empty section is sent.
Future<String?> buildLibraryDigest(WidgetRef ref) async {
  final sections = <String>[];
  final now = DateTime.now();

  // The open book goes first. Without its id, asked about a character in it,
  // the model looked the name up in the encyclopedia, then had to ask which
  // book was open before it could search the book.
  final reading = ref.read(currentReadingProvider);
  if (reading.isReading && reading.book != null) {
    final book = reading.book!;
    final parts = <String>[
      '#${book.id} ${book.title} — ${book.author}',
      '${(book.readingPercentage * 100).toStringAsFixed(0)}% read',
    ];
    final chapter = reading.chapterTitle?.trim();
    if (chapter != null && chapter.isNotEmpty) {
      parts.add('currently in "$chapter"');
    }
    final line = '[Now reading] ${parts.join(' · ')}';
    AnxLog.info('LocalLlm digest: $line');
    sections.add('$line\n'
        '  The reader has this book open. "This book", and any character, '
        'place or event the question names, mean this book: search it with '
        'library_search (book_id ${book.id}) or book_content_search '
        '(bookId ${book.id}), or read the current chapter with '
        'current_chapter_content.');
  }

  sections.add('[Today] ${_date(now)}');

  try {
    final books = await const BooksRepository().searchBooks(limit: 200);
    if (books.isNotEmpty) {
      final sorted = books.map((result) => result.book).toList()
        ..sort((a, b) => b.readingPercentage.compareTo(a.readingPercentage));
      final unread =
          sorted.where((book) => book.readingPercentage <= 0).toList();
      final started =
          sorted.where((book) => book.readingPercentage > 0).toList();

      // Ids are included because the only way to act on the shelf — the
      // bookshelf_organize tool — takes book ids, and a model that has never
      // seen one will make them up.
      final lines = <String>[
        '[Shelf] ${books.length} books (#id title — author · progress)',
      ];
      for (final book in started.take(_shelfLimit)) {
        lines.add('  #${book.id} ${book.title} — ${book.author} · '
            '${(book.readingPercentage * 100).toStringAsFixed(0)}%');
      }
      // Real group ids, so a reorganization can move books into folders that
      // exist instead of inventing ids for them.
      try {
        final groups = await const GroupsRepository().fetchAll();
        if (groups.isNotEmpty) {
          final counts = <int, int>{};
          for (final book in books.map((r) => r.book)) {
            if (book.groupId > 0) {
              counts[book.groupId] = (counts[book.groupId] ?? 0) + 1;
            }
          }
          lines.add('  Groups (#id name · books): ${groups.take(_shelfLimit).map((g) => '#${g.id} ${g.name} · ${counts[g.id] ?? 0}').join('; ')}');
        }
      } catch (e) {
        AnxLog.info('LocalLlm digest: groups unavailable ($e)');
      }
      if (unread.isNotEmpty) {
        final names = unread
            .take(_shelfLimit)
            .map((b) => '#${b.id} ${b.title}')
            .join('; ');
        lines.add('  Not started (${unread.length}): $names');
      }
      sections.add(lines.join('\n'));
    }
  } catch (e) {
    AnxLog.info('LocalLlm digest: shelf unavailable ($e)');
  }

  try {
    final history = await const ReadingHistoryRepository().fetchHistory(
      from: now.subtract(const Duration(days: 7)),
      limit: _historyLimit,
    );
    if (history.isNotEmpty) {
      final lines = <String>['[Read in the last 7 days]'];
      for (final record in history) {
        lines.add('  ${record.entry.date} · ${record.book.title} · '
            '${_minutes(record.entry.readingTime)}');
      }
      sections.add(lines.join('\n'));
    }
  } catch (e) {
    AnxLog.info('LocalLlm digest: history unavailable ($e)');
  }

  try {
    final notes = await const NotesRepository().searchNotes(limit: _noteLimit);
    if (notes.isNotEmpty) {
      final lines = <String>['[Recent notes and bookmarks]'];
      for (final result in notes) {
        final chapter = result.note.chapter.trim();
        final where = chapter.isEmpty ? '' : ' · $chapter';
        lines.add('  ${result.book.title}$where · '
            '${_date(result.note.updateTime)} · "${_clip(result.note)}"');
      }
      sections.add(lines.join('\n'));
    }
  } catch (e) {
    AnxLog.info('LocalLlm digest: notes unavailable ($e)');
  }

  if (sections.length <= 1) return null;

  // Tools are still offered alongside this. Each tool round trip costs a full
  // generation on a phone, so the model is steered to answer from what it
  // already has and reach for a tool only when that falls short.
  return 'The sections below are what you already know of this reader\'s own '
      'library. Answer from them when they contain the answer. Call a tool '
      'only when they do not, or when the reader asks you to change something. '
      'Never invent a title, a date, an id or a note.\n\n'
      '${sections.join('\n\n')}';
}

String _date(DateTime value) {
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  return '${value.year}-$month-$day';
}

String _minutes(int seconds) {
  if (seconds < 60) return '${seconds}s';
  final minutes = seconds ~/ 60;
  if (minutes < 60) return '${minutes}min';
  return '${minutes ~/ 60}h${(minutes % 60).toString().padLeft(2, '0')}';
}

String _clip(dynamic note) {
  final readerNote = (note.readerNote as String?)?.trim();
  final text = (readerNote != null && readerNote.isNotEmpty)
      ? readerNote
      : (note.content as String).trim();
  final flat = text.replaceAll(RegExp(r'\s+'), ' ');
  if (flat.length <= _snippetLimit) return flat;
  return '${flat.substring(0, _snippetLimit - 1)}…';
}
