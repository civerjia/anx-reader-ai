import 'package:flutter/material.dart';

/// A one-tap prompt offered on the AI chat screen.
///
/// Deliberately a plain class rather than freezed: it carries a callback, and
/// nothing ever copied or compared one.
class AiQuickPromptChip {
  const AiQuickPromptChip({
    required this.icon,
    required this.label,
    required this.prompt,
    this.attachment,
  });

  final IconData icon;
  final String label;

  /// The text put into the input box, which is what the user sees and can edit.
  final String prompt;

  /// Material the prompt cannot work without, fetched when the chip is tapped
  /// and appended to the message on send.
  ///
  /// "Summarize this chapter" says nothing about which chapter. Until now that
  /// was left to the tool-calling agent to go and find, which means it silently
  /// produced fiction when no book was open, and could never work at all with a
  /// local model — those have no tools wired to them. Attaching the text
  /// directly makes the prompt self-contained.
  final Future<String> Function()? attachment;
}
