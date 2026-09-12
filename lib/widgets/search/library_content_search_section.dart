import 'dart:async';
import 'dart:io';

import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/service/book.dart';
import 'package:anx_reader/service/search/library_content_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The "in the text" part of the search page.
///
/// Started by hand rather than on every keystroke: it opens every book in turn,
/// which on a large shelf takes a while.
class LibraryContentSearchSection extends ConsumerStatefulWidget {
  const LibraryContentSearchSection({super.key, required this.query});

  final String query;

  @override
  ConsumerState<LibraryContentSearchSection> createState() =>
      _LibraryContentSearchSectionState();
}

class _LibraryContentSearchSectionState
    extends ConsumerState<LibraryContentSearchSection> {
  LibraryContentSearch? _search;
  StreamSubscription<LibraryContentProgress>? _subscription;
  LibraryContentProgress? _progress;

  @override
  void didUpdateWidget(covariant LibraryContentSearchSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Results for a different query would be misleading; start over.
    if (oldWidget.query.trim() != widget.query.trim()) _stop(reset: true);
  }

  @override
  void dispose() {
    _search?.cancel();
    _subscription?.cancel();
    super.dispose();
  }

  void _start() {
    final keyword = widget.query.trim();
    if (keyword.isEmpty) return;
    _stop(reset: true);
    final search = LibraryContentSearch(ref);
    _search = search;
    _subscription = search.run(keyword).listen((progress) {
      if (!mounted) return;
      setState(() => _progress = progress);
    });
  }

  void _stop({bool reset = false}) {
    _search?.cancel();
    if (reset) {
      _subscription?.cancel();
      _subscription = null;
      _search = null;
      _progress = null;
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);

    if (Platform.isWindows) {
      return Text(l10n.searchFullTextUnavailable,
          style: theme.textTheme.bodyMedium);
    }

    final progress = _progress;
    final running = progress != null && !progress.done;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (progress == null) ...[
          OutlinedButton.icon(
            onPressed: widget.query.trim().isEmpty ? null : _start,
            icon: const Icon(Icons.manage_search),
            label: Text(l10n.searchFullTextStart),
          ),
          const SizedBox(height: 6),
          Text(l10n.searchFullTextHint, style: theme.textTheme.bodySmall),
        ] else ...[
          if (running) ...[
            LinearProgressIndicator(
              value: progress.total == 0 ? null : progress.scanned / progress.total,
            ),
            const SizedBox(height: 6),
          ],
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.searchFullTextProgress(
                    progress.scanned,
                    progress.total,
                    progress.hits.length,
                  ),
                  style: theme.textTheme.bodySmall,
                ),
              ),
              if (running)
                TextButton(
                  onPressed: _search?.cancelled == true ? null : _stop,
                  child: Text(l10n.searchFullTextStop),
                )
              else
                TextButton(
                  onPressed: _start,
                  child: Text(l10n.searchFullTextStart),
                ),
            ],
          ),
          if (progress.done && progress.hits.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(l10n.searchFullTextNone,
                  style: theme.textTheme.bodyMedium),
            ),
          for (final hit in progress.hits) _hitTile(context, hit),
        ],
      ],
    );
  }

  Widget _hitTile(BuildContext context, LibraryContentHit hit) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(hit.book.title, style: theme.textTheme.titleSmall),
          for (final match in hit.matches)
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () =>
                  pushToReadingPage(ref, context, hit.book, cfi: match.cfi),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (match.chapter.isNotEmpty)
                      Text(match.chapter,
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                    Text.rich(
                      TextSpan(children: [
                        TextSpan(text: match.pre),
                        TextSpan(
                          text: match.match,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        TextSpan(text: match.post),
                      ]),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
