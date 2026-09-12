import 'package:anx_reader/dao/base_dao.dart';
import 'package:anx_reader/models/book_series.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Series read from book files, one row per book that has been read.
///
/// A row without a name records that the book names no series, so it is not
/// read again. This is a table of its own, created whenever the database opens,
/// rather than columns on tb_books behind a schema bump: the synced database is
/// shared with installs that expect version 7, and a table they do not know
/// leaves them untouched. If such an install replaces the file, the table is
/// recreated empty and the books are simply read again.
const createBookSeriesSQL = '''
CREATE TABLE IF NOT EXISTS tb_book_series (
  book_id INTEGER PRIMARY KEY,
  name TEXT,
  position REAL
)
''';

class SeriesDao extends BaseDao {
  static const String table = 'tb_book_series';

  Future<Map<int, BookSeries?>> fetchAll() async {
    final rows = await rawQueryList(
      'SELECT book_id, name, position FROM $table',
      mapper: (row) {
        final name = row['name'] as String?;
        return MapEntry(
          row['book_id'] as int,
          name == null
              ? null
              : BookSeries(name, (row['position'] as num?)?.toDouble()),
        );
      },
    );
    return Map.fromEntries(rows);
  }

  Future<void> saveAll(Map<int, BookSeries?> series) async {
    if (series.isEmpty) return;
    await transaction((txn) async {
      final batch = txn.batch();
      for (final MapEntry(key: bookId, value: entry) in series.entries) {
        batch.insert(
          table,
          {'book_id': bookId, 'name': entry?.name, 'position': entry?.position},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }
}

final seriesDao = SeriesDao();
