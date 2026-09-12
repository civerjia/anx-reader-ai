import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/enums/ai_prompts.dart';
import 'package:langchain_core/chat_models.dart';

/// How many tokens a local model may spend on one answer.
///
/// One number for everything is wrong here. Generation is the slow part — a
/// phone manages roughly 20 tok/s — so the budget is a latency decision, and
/// what counts as patient differs completely between looking a word up and
/// asking for a mind map. Too low and the answer stops mid-sentence; too high
/// and a dictionary lookup keeps you waiting for a minute.
///
/// [promptTokens] only matters for translation, where the reply is the input
/// again in another language.
int localAnswerBudget(AiPrompts? purpose, {int promptTokens = 0}) {
  switch (purpose) {
    // A gloss plus a few senses for one word or phrase.
    case AiPrompts.translate:
      return 512;

    // The reply is the passage translated, so it needs at least the room the
    // passage took. Half again for a target language that runs longer, and a
    // ceiling because a whole chapter would take many minutes either way.
    case AiPrompts.fullTextTranslate:
      return (promptTokens * 3 ~/ 2).clamp(512, 4096);

    // The built-in prompt asks for 8-10 sentences in three paragraphs.
    case AiPrompts.summaryTheChapter:
    case AiPrompts.summaryTheBook:
      return 1536;

    // Three to five sentences of recap.
    case AiPrompts.summaryThePreviousContent:
      return 512;

    // Every branch of a nested outline: the longest thing the app asks for.
    case AiPrompts.mindmap:
      return 3072;

    // A self-introduction, used to check the provider answers at all.
    case AiPrompts.test:
      return 256;

    // Free chat. Here it is the user's patience that sets the limit, so it is
    // the one budget worth exposing as a setting.
    case null:
      return Prefs().localLlmMaxTokens;
  }
}

/// A rough token count for [messages], good enough to size a translation.
///
/// llama.cpp tokenizes in its own isolate and asking it would mean a round trip
/// before the real work starts. CJK runs close to one token per character while
/// Latin script is nearer four characters per token, so count the two
/// separately rather than applying one ratio to both.
int estimateTokens(List<ChatMessage> messages) {
  var cjk = 0;
  var other = 0;
  for (final message in messages) {
    for (final rune in message.contentAsString.runes) {
      if (_isCjk(rune)) {
        cjk++;
      } else {
        other++;
      }
    }
  }
  return cjk + (other / 4).ceil();
}

bool _isCjk(int rune) {
  return (rune >= 0x3000 && rune <= 0x9FFF) || // punctuation, kana, unified han
      (rune >= 0xF900 && rune <= 0xFAFF) || // compatibility ideographs
      (rune >= 0xFF00 && rune <= 0xFF60) || // fullwidth forms
      (rune >= 0x20000 && rune <= 0x2FA1F); // extensions B-F
}
