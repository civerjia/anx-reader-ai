import 'dart:async';

import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/service/ai/tools/ai_tool_registry.dart';
import 'package:anx_reader/service/library_index/library_index.dart';

import 'base_tool.dart';

class LibrarySearchInput {
  const LibrarySearchInput({required this.query, this.bookId, this.limit = 5});

  final String query;
  final int? bookId;
  final int limit;

  factory LibrarySearchInput.fromJson(Map<String, dynamic> json) =>
      LibrarySearchInput(
        query: (json['query'] ?? json['keyword'] ?? '').toString(),
        bookId: (json['book_id'] ?? json['bookId']) is num
            ? ((json['book_id'] ?? json['bookId']) as num).toInt()
            : int.tryParse('${json['book_id'] ?? json['bookId'] ?? ''}'),
        limit: ((json['limit'] as num?)?.toInt() ?? 5).clamp(1, 10),
      );

  Map<String, dynamic> toJson() => {
        'query': query,
        if (bookId != null) 'book_id': bookId,
        'limit': limit,
      };
}

/// Finds passages across every book the reader has, from the full-text index.
/// A small model cannot hold a library in its context; it can ask for the few
/// passages that matter.
class LibrarySearchTool
    extends RepositoryTool<LibrarySearchInput, Map<String, dynamic>> {
  LibrarySearchTool()
      : super(
          name: 'library_search',
          description:
              "Search the text of all the reader's books at once and get back the best matching passages, "
              'each with its book id, title and chapter. Use it to find which book mentions a name, event or idea, '
              'to gather what the books say about something, or, with book_id, to search one book quickly. '
              'Query with the words likely to appear in the passage, such as a name or a short phrase. '
              'Answer from the passages and name the book they come from.',
          inputJsonSchema: const {
            'type': 'object',
            'properties': {
              'query': {
                'type': 'string',
                'description': 'Words to look for, such as a name or a short phrase.',
              },
              'book_id': {
                'type': 'integer',
                'description': 'Optional. Only search this book.',
              },
              'limit': {
                'type': 'integer',
                'description': 'Optional. How many passages to return, 1-10 (default 5).',
              },
            },
            'required': ['query'],
          },
          timeout: const Duration(seconds: 20),
        );

  @override
  LibrarySearchInput parseInput(Map<String, dynamic> json) =>
      LibrarySearchInput.fromJson(json);

  @override
  Future<Map<String, dynamic>> run(LibrarySearchInput input) async {
    final query = input.query.trim();
    if (query.isEmpty) throw ArgumentError('query must not be empty');
    final index = LibraryIndex.instance;
    final indexed = await index.indexedBookIds();
    if (indexed.isEmpty) {
      unawaited(index.updateAll());
      return {
        'query': query,
        'results': const [],
        'note': 'The full-text index of the library has not been built yet; '
            'it is being built now. Tell the reader, and use '
            'book_content_search for a single book meanwhile.',
      };
    }
    if (input.bookId != null && !indexed.contains(input.bookId)) {
      unawaited(index.updateAll());
      return {
        'query': query,
        'book_id': input.bookId,
        'results': const [],
        'note': 'That book is not in the index yet. Use book_content_search '
            'with bookId ${input.bookId} instead.',
      };
    }
    final passages =
        await index.search(query, bookId: input.bookId, limit: input.limit);
    return {
      'query': query,
      if (input.bookId != null) 'book_id': input.bookId,
      'results': [
        for (final (passage, title) in passages) passage.toMap(bookTitle: title),
      ],
      if (passages.isEmpty)
        'note': 'No passage in the indexed books matches. Try fewer or '
            'different words.',
    };
  }
}

final AiToolDefinition librarySearchToolDefinition = AiToolDefinition(
  id: 'library_search',
  displayNameBuilder: (L10n l10n) => l10n.aiToolLibrarySearchName,
  descriptionBuilder: (L10n l10n) => l10n.aiToolLibrarySearchDescription,
  build: (context) => LibrarySearchTool().tool,
);
