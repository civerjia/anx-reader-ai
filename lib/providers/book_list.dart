import 'dart:async';
import 'dart:isolate';

import 'package:anx_reader/service/series/volume_order.dart';
import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/dao/series.dart';
import 'package:anx_reader/dao/tag.dart';
import 'package:anx_reader/enums/sort_field.dart';
import 'package:anx_reader/enums/sort_order.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/book_series.dart';
import 'package:anx_reader/providers/tb_groups.dart';
import 'package:anx_reader/providers/book_filters.dart';
import 'package:anx_reader/providers/tags.dart'
    show kNoTagFilterId, tagSelectionProvider;
import 'package:anx_reader/service/series/book_series.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:lpinyin/lpinyin.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'book_list.g.dart';

// Top level so the isolate closure carries only the paths, never the notifier.
Future<Map<int, BookSeries?>> _readSeriesInBackground(Map<int, String> paths) =>
    Isolate.run(() => readSeriesOfFiles(paths));

@riverpod
class BookList extends _$BookList {
  List<List<Book>> groupBooks(List<Book> books) {
    var groupedBooks = <List<Book>>[];
    for (var book in books) {
      if (book.groupId == 0) {
        groupedBooks.add([book]);
      } else {
        var existingGroup = groupedBooks.firstWhere(
          (group) => group.first.groupId == book.groupId,
          orElse: () => [],
        );
        if (existingGroup.isEmpty) {
          groupedBooks.add([book]);
        } else {
          existingGroup.add(book);
        }
      }
    }
    // Within a folder, the volumes of a series in order (三体Ⅰ, Ⅱ, Ⅲ), so its
    // cover is the first volume.
    return [
      for (final group in groupedBooks)
        group.length > 1
            ? orderVolumes(group, title: (b) => b.title, series: (b) => b.series)
            : group,
    ];
  }

  int getChineseCompareResult(String a, String b) {
    String pinyina = '';
    String pinyinb = '';
    try {
      pinyina = PinyinHelper.getPinyin(a, format: PinyinFormat.WITHOUT_TONE);
    } catch (e) {
      pinyina = a;
    }
    try {
      pinyinb = PinyinHelper.getPinyin(b, format: PinyinFormat.WITHOUT_TONE);
    } catch (e) {
      pinyinb = b;
    }

    return pinyina.compareTo(pinyinb);
  }

  List<Book> sortBooks(List<Book> books) {
    if (Prefs().sortField == SortFieldEnum.series) {
      final descending = Prefs().sortOrder == SortOrderEnum.descending;
      books.sort((a, b) {
        final bySeries = compareBySeries(a.series, b.series,
            compareNames: getChineseCompareResult, descending: descending);
        return bySeries != 0
            ? bySeries
            : getChineseCompareResult(a.title, b.title);
      });
      return books;
    }
    books.sort((a, b) {
      int compareResult;
      switch (Prefs().sortField) {
        case SortFieldEnum.title:
          compareResult = getChineseCompareResult(a.title, b.title);
          break;
        case SortFieldEnum.author:
          compareResult = getChineseCompareResult(a.author, b.author);
          break;
        case SortFieldEnum.lastReadTime:
          compareResult = a.updateTime.compareTo(b.updateTime);
          break;
        case SortFieldEnum.progress:
          compareResult = a.readingPercentage.compareTo(b.readingPercentage);
          break;
        case SortFieldEnum.importTime:
          compareResult = a.createTime.compareTo(b.createTime);
          break;
        case SortFieldEnum.series:
          // Sorted above: series order ignores the direction within a series.
          compareResult = 0;
          break;
      }
      return Prefs().sortOrder == SortOrderEnum.ascending
          ? compareResult
          : -compareResult;
    });
    return books;
  }

  bool _matchesStatus(Book book, ReadingStatusFilter status) {
    const notStartThreshold = 0.02;
    const finishedThreshold = 0.98;
    switch (status) {
      case ReadingStatusFilter.none:
        return true;
      case ReadingStatusFilter.finished:
        return book.readingPercentage >= finishedThreshold;
      case ReadingStatusFilter.reading:
        return book.readingPercentage > notStartThreshold &&
            book.readingPercentage < finishedThreshold;
      case ReadingStatusFilter.notStarted:
        return book.readingPercentage <= notStartThreshold;
    }
  }

  Future<List<List<Book>>> _buildWithFilters({String? query}) async {
    final status = ref.watch(readingStatusFilterNotifierProvider);
    final selectedTags = ref.watch(tagSelectionProvider);

    final books = await bookDao.selectNotDeleteBooks();
    final series = await seriesDao.fetchAll();
    for (final book in books) {
      book.series = series[book.id];
    }
    unawaited(_readMissingSeries(books, series));
    final filteredByQuery = query == null || query.isEmpty
        ? books
        : books
            .where(
              (book) =>
                  book.title.contains(query) ||
                  book.author.contains(query) ||
                  (book.series?.name.contains(query) ?? false),
            )
            .toList();

    final filteredByStatus =
        filteredByQuery.where((book) => _matchesStatus(book, status)).toList();

    List<Book> filteredByTags = filteredByStatus;
    if (selectedTags.isNotEmpty) {
      final tagMap = await bookTagDao.bookIdToTagIds(
          bookIds: filteredByStatus.map((b) => b.id).toList());
      if (selectedTags.contains(kNoTagFilterId)) {
        // Filter books without any tags
        filteredByTags = filteredByStatus.where((book) {
          final tags = tagMap[book.id];
          return tags == null || tags.isEmpty;
        }).toList();
      } else {
        // Filter books that contain all selected tags
        filteredByTags = filteredByStatus.where((book) {
          final tags = tagMap[book.id];
          if (tags == null || tags.isEmpty) return false;
          return selectedTags.every((id) => tags.contains(id));
        }).toList();
      }
    }

    final sortedBooks = sortBooks(filteredByTags);
    return groupBooks(sortedBooks);
  }

  static bool _readingSeries = false;

  /// Reads the series of books not read before — new imports, and the whole
  /// library the first time — off the UI isolate, then shows what it found.
  Future<void> _readMissingSeries(
      List<Book> books, Map<int, BookSeries?> known) async {
    if (_readingSeries) return;
    final paths = {
      for (final book in books)
        if (!known.containsKey(book.id)) book.id: book.fileFullPath,
    };
    if (paths.isEmpty) return;
    _readingSeries = true;
    try {
      final found = await _readSeriesInBackground(paths);
      await seriesDao.saveAll(found);
      if (found.values.any((series) => series != null)) await refresh();
    } catch (e) {
      AnxLog.info('Series: reading book files failed: $e');
    } finally {
      _readingSeries = false;
    }
  }

  @override
  Future<List<List<Book>>> build() async {
    return _buildWithFilters();
  }

  Future<void> refresh() async {
    state = AsyncData(await _buildWithFilters());
  }

  /// Puts [books] into the folder [groupId] at once, creating it with [name]
  /// when it does not exist, and refreshes the shelf once.
  Future<void> moveBooks(List<Book> books, int groupId, {String? name}) async {
    await ref.read(groupDaoProvider.notifier).insertGroup(groupId, name: name);
    for (final book in books) {
      await bookDao.updateBook(book.copyWith(groupId: groupId));
    }
    await refresh();
  }

  void moveBook(Book data, int groupId) {
    updateBook(data.copyWith(groupId: groupId));
    // insert a new group if not exists; seed name from the dropped book title
    ref.read(groupDaoProvider.notifier).insertGroup(groupId, name: data.title);
    refresh();
  }

  void updateBook(Book book) {
    bookDao.updateBook(book);
    refresh();
  }

  void dissolveGroup(List<Book> books) {
    for (var book in books) {
      updateBook(book.copyWith(groupId: 0));
    }
    // delete the group
    ref.read(groupDaoProvider.notifier).hardDeleteGroup(books.first.groupId);
    refresh();
  }

  void removeFromGroup(Book book) {
    updateBook(book.copyWith(groupId: 0));
    refresh();
  }

  void reorder(List<List<Book>> books) {
    state = AsyncData(books);
  }

  void moveBookToTop(int bookId) {
    var groups = state.value!.map((group) {
      if (group.any((book) => book.id == bookId)) {
        return [
          group.firstWhere((book) => book.id == bookId),
          ...group.where((b) => b.id != bookId)
        ];
      }
      return group;
    }).toList();

    state = AsyncData([
      groups.firstWhere((group) => group.any((book) => book.id == bookId)),
      ...groups.where((group) => group.every((book) => book.id != bookId))
    ]);
  }

  Future<void> search(String? value) async {
    state = AsyncData(await _buildWithFilters(query: value));
  }
}
