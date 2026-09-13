import 'package:anx_reader/providers/bookshelf_selection.dart';
import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/enums/book_sync_status.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/providers/sync_status.dart';
import 'package:anx_reader/service/book.dart';
import 'package:anx_reader/widgets/bookshelf/book_bottom_sheet.dart';
import 'package:anx_reader/widgets/common/anx_bottom_sheet.dart';
import 'package:anx_reader/widgets/bookshelf/book_cover.dart';
import 'package:anx_reader/widgets/bookshelf/book_sync_status_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class BookItem extends ConsumerWidget {
  const BookItem({
    super.key,
    required this.book,
  });

  final Book book;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Future<void> handleLongPress(BuildContext context) async {
      showAnxBottomSheet(
          context: context,
          builder: (BuildContext context) {
            return BookBottomSheet(book: book);
          });
    }

    BookSyncStatusEnum bookSyncStatus =
        ref.watch(syncStatusProvider).whenOrNull(data: (data) {
              if (data.downloading.contains(book.id)) {
                return BookSyncStatusEnum.downloading;
              } else if (data.uploading.contains(book.id)) {
                return BookSyncStatusEnum.uploading;
              } else if (data.localOnly.contains(book.id)) {
                return BookSyncStatusEnum.localOnly;
              } else if (data.remoteOnly.contains(book.id)) {
                return BookSyncStatusEnum.remoteOnly;
              } else if (data.both.contains(book.id)) {
                return BookSyncStatusEnum.both;
              } else if (data.nonExistent.contains(book.id)) {
                return BookSyncStatusEnum.nonExistent;
              } else {
                return BookSyncStatusEnum.checking;
              }
            }) ??
            BookSyncStatusEnum.checking;

    final shelfSelection = ref.watch(bookshelfSelectionProvider);
    void toggleSelected() {
      final next = {...?shelfSelection};
      if (!next.remove(book.id)) next.add(book.id);
      ref.read(bookshelfSelectionProvider.notifier).state = next;
    }

    return GestureDetector(
      onTap: () {
        if (shelfSelection != null) {
          toggleSelected();
          return;
        }
        pushToReadingPage(ref, context, book);
      },
      onLongPress: () {
        if (shelfSelection != null) {
          toggleSelected();
          return;
        }
        handleLongPress(context);
      },
      onSecondaryTap: () {
        handleLongPress(context);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Hero(
              tag: book.coverFullPath,
              child: Container(
                decoration: BoxDecoration(
                  boxShadow: [
                    if (!Prefs().eInkMode)
                      BoxShadow(
                        color: Colors.grey.withAlpha(100),
                        spreadRadius: 5,
                        blurRadius: 10,
                        offset: const Offset(0, 2),
                      ),
                  ],
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          BookCover(book: book),
                          if (shelfSelection != null)
                            Positioned(
                              top: 4,
                              right: 4,
                              child: Icon(
                                shelfSelection.contains(book.id)
                                    ? Icons.check_circle
                                    : Icons.radio_button_unchecked,
                                color: shelfSelection.contains(book.id)
                                    ? Theme.of(context).colorScheme.primary
                                    : Colors.white,
                                shadows: const [
                                  Shadow(blurRadius: 4, color: Colors.black54),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 5),
          SizedBox(
            height: 55,
            child: Column(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        book.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    if (Prefs().webdavStatus)
                      SizedBox(
                        height: 20,
                        width: 20,
                        child: BookSyncStatusIcon(
                          syncStatus: bookSyncStatus,
                        ),
                      ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        book.series == null
                            ? book.author
                            : '${book.series!.label} · ${book.author}',
                        style: const TextStyle(
                            fontWeight: FontWeight.w300,
                            fontSize: 9,
                            overflow: TextOverflow.ellipsis),
                      ),
                    ),
                    Text(
                      '${(book.readingPercentage * 100).toStringAsFixed(0)}%',
                      style: const TextStyle(
                          fontWeight: FontWeight.w300,
                          fontSize: 9,
                          overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
