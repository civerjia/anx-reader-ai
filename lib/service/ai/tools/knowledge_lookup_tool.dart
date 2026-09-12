import 'dart:async';

import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/service/ai/tools/ai_tool_registry.dart';
import 'package:anx_reader/service/knowledge/knowledge_library.dart';
import 'package:anx_reader/service/knowledge/knowledge_service.dart';

import 'base_tool.dart';

class KnowledgeLookupInput {
  const KnowledgeLookupInput({required this.query, this.maxCharacters = 1200});

  final String query;
  final int maxCharacters;

  factory KnowledgeLookupInput.fromJson(Map<String, dynamic> json) =>
      KnowledgeLookupInput(
        query: (json['query'] ?? json['title'] ?? '').toString(),
        maxCharacters:
            ((json['max_characters'] as num?)?.toInt() ?? 1200).clamp(200, 4000),
      );

  Map<String, dynamic> toJson() => {
        'query': query,
        'max_characters': maxCharacters,
      };
}

/// Lets the model check facts against the offline Wikipedia packs instead of
/// relying on what it remembers — a small local model invents details about
/// anything it has not seen often.
class KnowledgeLookupTool
    extends RepositoryTool<KnowledgeLookupInput, Map<String, dynamic>> {
  KnowledgeLookupTool(this._library)
      : super(
          name: 'knowledge_lookup',
          description:
              'Look up an encyclopedia article in the offline Wikipedia packs on this device. '
              'Use it before stating facts about a person, place, organism or species, chemical, event, work or term, '
              'including when asked what a name means or how to translate it. '
              'Query with the article title: the most likely name of the thing, such as its scientific or proper name '
              '(for example "Artemisia arborescens" or "氢"). '
              'Answer from the returned text, cite the article title, and say plainly when nothing was found instead of guessing. '
              'When there is no exact title it returns similar titles you can look up next.',
          inputJsonSchema: const {
            'type': 'object',
            'properties': {
              'query': {
                'type': 'string',
                'description': 'The article title to look up.',
              },
              'max_characters': {
                'type': 'integer',
                'description':
                    'Optional. How much of the article to return, 200-4000 characters (default 1200).',
              },
            },
            'required': ['query'],
          },
          timeout: const Duration(seconds: 20),
        );

  final KnowledgeLibrary _library;

  @override
  KnowledgeLookupInput parseInput(Map<String, dynamic> json) =>
      KnowledgeLookupInput.fromJson(json);

  @override
  Future<Map<String, dynamic>> run(KnowledgeLookupInput input) async {
    if (input.query.trim().isEmpty) {
      return {'found': false, 'note': 'Give the title of the article to look up.'};
    }
    final packs = await _library.installed();
    if (packs.isEmpty) {
      return {
        'found': false,
        'note': 'No offline encyclopedia pack is installed on this device.',
      };
    }
    final result =
        await _library.lookup(input.query, maxCharacters: input.maxCharacters);
    if (result.hits.isNotEmpty) {
      return {
        'found': true,
        'articles': [
          for (final hit in result.hits)
            {
              'title': hit.title,
              'source': hit.pack.title,
              'text': hit.text,
            },
        ],
      };
    }
    return {
      'found': false,
      'note': 'No article has exactly this title.',
      if (result.suggestions.isNotEmpty) 'similar_titles': result.suggestions,
    };
  }
}

final AiToolDefinition knowledgeLookupToolDefinition = AiToolDefinition(
  id: 'knowledge_lookup',
  displayNameBuilder: (L10n l10n) => l10n.aiToolKnowledgeLookupName,
  descriptionBuilder: (L10n l10n) => l10n.aiToolKnowledgeLookupDescription,
  build: (context) => KnowledgeLookupTool(knowledgeLibrary).tool,
);
