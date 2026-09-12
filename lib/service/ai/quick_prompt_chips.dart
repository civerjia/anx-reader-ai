import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/ai_quick_prompt_chip.dart';
import 'package:anx_reader/models/user_prompt.dart';
import 'package:anx_reader/providers/current_reading.dart';
import 'package:anx_reader/service/ai/prompt_generate.dart';
import 'package:anx_reader/service/ai/tools/repository/chapter_content_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsx_plus/iconsx_plus.dart';

/// How much of a chapter to send along.
///
/// The local model is loaded with an 8192 token context by default and a Chinese
/// character is roughly one token, so this leaves room for the prompt and a
/// full-length answer. A remote model can still reach for more through the
/// chapter tools.
const int _chapterCharacterLimit = 4000;

/// The one-tap prompts offered on the chat screen.
///
/// "Summarize this chapter" and "summarize this book" only mean something while
/// a book is open, so they are not offered otherwise — on the home screen they
/// used to be there with nothing behind them, and the model would answer about
/// a book nobody had named. The ones that are offered say which book or chapter
/// they mean and carry that text with them.
List<AiQuickPromptChip> buildAiQuickPromptChips(
  BuildContext context,
  WidgetRef ref,
) {
  final l10n = L10n.of(context);
  final reading = ref.read(currentReadingProvider);
  final chips = <AiQuickPromptChip>[];

  if (reading.isReading) {
    final bookTitle = reading.book?.title;
    final chapterTitle = reading.chapterTitle;

    chips.add(
      AiQuickPromptChip(
        icon: EvaIcons.book,
        label: _withDetail(l10n.settingsAiPromptSummaryTheChapter, chapterTitle),
        prompt: generatePromptSummaryTheChapter().buildString(),
        attachment: () => _currentChapterAttachment(ref),
      ),
    );
    chips.add(
      AiQuickPromptChip(
        icon: Icons.menu_book_rounded,
        label: _withDetail(l10n.settingsAiPromptSummaryTheBook, bookTitle),
        prompt: generatePromptSummaryTheBook().buildString(),
        attachment: () async => _bookAttachment(ref),
      ),
    );
    chips.add(
      AiQuickPromptChip(
        icon: Icons.account_tree_outlined,
        label: _withDetail(l10n.settingsAiPromptMindmap, chapterTitle),
        prompt: generatePromptMindmap().buildString(),
        attachment: () => _currentChapterAttachment(ref),
      ),
    );
  }

  final List<UserPrompt> userPrompts = Prefs().userPrompts;
  chips.addAll(
    userPrompts.where((prompt) => prompt.enabled).map(
          (prompt) => AiQuickPromptChip(
            icon: Icons.person_outline,
            label: prompt.name,
            prompt: prompt.content,
          ),
        ),
  );

  return chips;
}

/// Names the target in the chip itself, so "summarize this chapter" cannot be
/// ambiguous about which one.
String _withDetail(String label, String? detail) {
  final trimmed = detail?.trim();
  if (trimmed == null || trimmed.isEmpty) return label;
  return '$label · $trimmed';
}

/// The section names follow the `[Previous Content]` convention the built-in
/// recap prompt already uses, so an edited prompt still reads coherently with
/// this appended to it.
Future<String> _currentChapterAttachment(WidgetRef ref) async {
  final reading = ref.read(currentReadingProvider);
  final content = await const ChapterContentRepository()
      .fetchCurrent(ref, maxCharacters: _chapterCharacterLimit);

  final lines = <String>[];
  final book = reading.book;
  if (book != null) {
    lines.add('[Book] ${book.title} — ${book.author}');
  }
  final chapter = reading.chapterTitle?.trim();
  if (chapter != null && chapter.isNotEmpty) {
    lines.add('[Chapter] $chapter');
  }
  lines.add('[Chapter Content]');
  lines.add(content);
  return lines.join('\n');
}

Future<String> _bookAttachment(WidgetRef ref) async {
  final book = ref.read(currentReadingProvider).book;
  if (book == null) {
    throw StateError('No active reading session.');
  }
  final lines = <String>['[Book] ${book.title} — ${book.author}'];
  final chapter = ref.read(currentReadingProvider).chapterTitle?.trim();
  if (chapter != null && chapter.isNotEmpty) {
    lines.add('[Reader is currently at] $chapter');
  }
  return lines.join('\n');
}
